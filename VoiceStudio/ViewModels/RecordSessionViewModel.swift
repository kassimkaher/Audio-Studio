import Foundation
import AVFoundation
import Combine

/// Drives the record screen: preset/effect selection, live monitoring, real-time
/// filter changes, take preview, and Approve/Discard. The committed take is
/// handed back to the editor as an `AudioSource` + the chosen `EffectChainSpec`.
@MainActor
final class RecordSessionViewModel: ObservableObject {
    @Published var selectedPresetID: String = PresetLibrary.anasheed.id
    @Published var chain: EffectChainSpec = PresetLibrary.anasheed.chain
    @Published var monitorEnabled = false
    @Published var errorMessage: String?
    @Published var showPermissionDenied = false

    /// Manual fine-tune (ms) added to the automatic overdub latency compensation.
    /// Positive = pull the take earlier (remove more delay); negative = push later.
    /// Persisted so the user only calibrates their headphones/interface once.
    @Published var syncOffsetMs: Double = UserDefaults.standard.double(forKey: "overdubSyncOffsetMs") {
        didSet { UserDefaults.standard.set(syncOffsetMs, forKey: "overdubSyncOffsetMs") }
    }

    /// The captured take, available after stopping and before Approve/Discard.
    @Published private(set) var recordedSource: AudioSource?

    // MARK: Live Audience / Majlis atmosphere controls
    //
    // A looping crowd ambience bed is heard live and auto-ducks under the reciter
    // (envelope-follower sidechain in `AudioEngineController`). The crowd is NOT
    // captured into the take — the mic tap is separate — so the vocal stem stays
    // clean while the Radoud performs "in front of the audience".

    /// Quick toggle on the record panel. Rebuilds the monitor graph to (un)wire
    /// the crowd lane.
    @Published var audienceModeEnabled = false {
        didSet {
            guard audienceModeEnabled != oldValue else { return }
            recordingService.setAudienceMode(audienceModeEnabled, chain: chain)
        }
    }
    /// Background crowd level (0...1) before ducking — applied live.
    @Published var crowdVolume: Float = 0.6 {
        didSet { engineController.setCrowdVolume(crowdVolume) }
    }
    /// How hard the crowd ducks while reciting (dB attenuation, −3…−18) — live.
    @Published var duckingAmountDb: Float = -9 {
        didSet { engineController.duckAmountDb = duckingAmountDb }
    }
    /// Ducking sensitivity: the input level that counts as "reciting" — live.
    @Published var duckingSensitivity: Float = 0.04 {
        didSet { engineController.duckThreshold = duckingSensitivity }
    }

    /// When ON, the next approved take is committed to the **active target track**
    /// (whatever the user selected) and tagged with the "Live Majlis / Crowd
    /// Presence" chain — for recording a Raddah / crowd layer, not the lead vocal.
    /// Independent of `audienceModeEnabled` (which is the live monitor atmosphere).
    @Published var isCrowdDesignatedTake = false

    /// Which existing tracks the performer hears while recording (overdub monitor).
    /// Live-switchable: `.all`, `.none`, or a single `.track(id)`.
    @Published var monitorScope: MonitorScope = .all {
        didSet { engineController.setMonitorScope(monitorScope) }
    }

    /// The timeline frame where recording began (the cursor) — backing playback
    /// starts here and the approved take is placed here.
    private var recordStartFrame: AVAudioFramePosition = 0

    private let env: AppEnvironment

    init(env: AppEnvironment) { self.env = env }

    var recordingService: RecordingService { env.recordingService }
    var engineController: AudioEngineController { env.engineController }
    var playback: PlaybackService { env.playbackService }
    var isRecording: Bool { recordingService.isRecording }
    var isMonitoringLive: Bool { recordingService.isMonitoring }
    var hasTake: Bool { recordedSource != nil }
    /// True when the current take was recorded over a backing track (overdub),
    /// so the sync fine-tune control is relevant.
    var isOverdubTake: Bool { hasTake && recordingService.lastWasOverdub }

    /// The clip currently being previewed (Listen), so filter edits can be
    /// pushed into the running preview as well as the live monitor.
    private var previewClip: Clip?

    /// Supplies the existing project to play as a backing track while recording
    /// (overdub). Set by the record view from the editor.
    var backingProvider: (() -> Project?)?

    /// Tracks available to monitor while recording (for the "hear" dropdown).
    var monitorTracks: [(id: UUID, name: String)] {
        (backingProvider?()?.tracks ?? []).map { ($0.id, $0.name) }
    }

    var wetDry: Float {
        get { chain.wetDryMix }
        set { chain.wetDryMix = newValue; pushLive() }
    }
    var intensity: Float {
        get { chain.intensity }
        set { chain.intensity = newValue; pushLive() }
    }

    func selectPreset(_ preset: VocalPreset) { applyChain(preset.chain) }

    /// Applies a chain (built-in preset or saved Mode) and pushes it live.
    func applyChain(_ newChain: EffectChainSpec) {
        chain = newChain
        pushLive()
    }
    func chainChanged() { pushLive() }

    /// Applies the current chain to whatever is sounding right now, and — when a
    /// take exists but nothing is playing — auto-auditions the take (looped) so
    /// filter edits are heard without pressing Listen.
    private func pushLive() {
        engineController.updateChain(chain)
        if let pc = previewClip {
            previewClip?.effectChain = chain
            playback.updateClipChain(pc.id, spec: chain)
        } else if !isRecording, let source = recordedSource, !playback.isPlaying {
            startPreview(source: source)
        }
    }

    private func startPreview(source: AudioSource) {
        // Release the input-monitor engine first: while it runs, the audio
        // session stays in play-and-record mode (which routes output to the
        // receiver, not the speaker), so the preview would render silently.
        recordingService.stopMonitoring()
        let clip = Clip(sourceID: source.id, sourceInFrame: 0, sourceOutFrame: source.frameCount,
                        timelineStartFrame: 0, effectChain: chain, name: "Take")
        previewClip = clip
        playback.previewClip(clip, source: source, loop: true)
    }

    func setMonitoring(_ on: Bool) {
        monitorEnabled = on
        recordingService.setMonitoringEnabled(on, chain: chain)
    }

    // MARK: Recording

    /// Screen appeared: list inputs and start the live input meter (after
    /// ensuring mic permission) so the waveform animates with the incoming voice.
    func appear() async {
        env.sessionManager.prepareForInputSelection()
        if env.sessionManager.permission != .granted {
            let granted = await env.sessionManager.requestPermission()
            if !granted { showPermissionDenied = true; return }
        }
        recordingService.startMonitoring(chain: chain, monitor: monitorEnabled)
    }

    func toggleRecording() async {
        if isRecording { stopRecording() } else { await startRecording() }
    }

    private func startRecording() async {
        let startFrame = max(0, playback.currentFrame)   // record + listen from the cursor
        recordStartFrame = startFrame
        playback.stop()
        previewClip = nil
        recordedSource = nil
        if env.sessionManager.permission != .granted {
            let granted = await env.sessionManager.requestPermission()
            if !granted { showPermissionDenied = true; return }
        }
        // Overdub: if the project already has audio, play it as a backing track —
        // starting from the cursor, scoped by the monitor selection.
        let backing = backingProvider?().flatMap { $0.totalFrames > 0 ? $0 : nil }
        do {
            try recordingService.start(chain: chain, monitor: monitorEnabled,
                                       backing: backing, from: startFrame)
            engineController.setMonitorScope(monitorScope)
        } catch { errorMessage = error.localizedDescription }
    }

    func stopRecording() {
        recordedSource = recordingService.stop()
        // Free the input engine so the take can be previewed cleanly.
        recordingService.stopMonitoring()
    }

    // MARK: Preview / commit

    func togglePreview() {
        guard let source = recordedSource else { return }
        if playback.isPlaying {
            playback.stop()
            previewClip = nil
        } else {
            startPreview(source: source)
        }
    }

    /// Commits the take to the **active target track** (dynamic — whatever the
    /// user selected; no hardcoded indices) and clears the session. If the take
    /// is designated a Crowd/Raddah layer, the Live Majlis chain is applied to
    /// that clip instead of the current preset.
    func approve(into editor: ProjectEditorViewModel, trackID: UUID?) {
        guard let source = recordedSource else { return }
        playback.stop()
        playback.seek(to: recordStartFrame)   // land the take where recording began (cursor)
        let target = trackID
            ?? editor.selectedTrackID
            ?? editor.project.tracks.first?.id
            ?? editor.addTrackReturningID()

        // Overdub latency compensation on the target track: automatic round-trip
        // latency + the user's manual fine-tune, so the take aligns with whatever
        // was playing back while recording.
        var align: AVAudioFramePosition = 0
        if recordingService.lastWasOverdub {
            let manual = AVAudioFramePosition((syncOffsetMs / 1000.0 * source.sampleRate).rounded())
            align = recordingService.lastLatencyFrames + manual
        }

        // Crowd/Raddah takes get the "Live Majlis / Crowd Presence" chain; lead
        // takes get the currently selected chain.
        let clipChain = isCrowdDesignatedTake ? PresetLibrary.liveMajlis.chain : chain
        let clipName = isCrowdDesignatedTake ? "Raddah / Crowd" : "Take"
        editor.appendClip(source: source, chain: clipChain, toTrack: target,
                          name: clipName, alignFrames: align)

        recordingService.relinquishFile()   // the clip now owns the file; don't delete on dismiss
        recordedSource = nil
        previewClip = nil
    }

    /// Discards the captured take and resumes the live input meter.
    func discardTake() {
        playback.stop()
        previewClip = nil
        if let s = recordedSource { try? FileManager.default.removeItem(at: s.url) }
        recordedSource = nil
        recordingService.startMonitoring(chain: chain, monitor: monitorEnabled)
    }

    /// Called when the screen closes — stop everything cleanly.
    func cancelAll() {
        recordingService.cancel()      // stops recording + monitoring, deletes pending file
        playback.stop()
        previewClip = nil
        if let s = recordedSource { try? FileManager.default.removeItem(at: s.url) }
        recordedSource = nil
        engineController.isMonitoringEnabled = false
    }
}
