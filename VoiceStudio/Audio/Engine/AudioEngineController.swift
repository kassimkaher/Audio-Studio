import Foundation
import AVFoundation
import Combine
import Accelerate

/// Which existing tracks the performer hears while recording (overdub monitor).
enum MonitorScope: Equatable { case all, none, track(UUID) }

/// Owns the live `AVAudioEngine` used for recording and real-time monitoring.
///
/// A single tap on the input node feeds the recording writer and the waveform
/// sampler with the raw signal. The input node is **never** connected to the
/// output — routing live input through the output IO unit crashes with
/// `isInputConnToConverter` whenever the mic's hardware rate differs from the
/// graph. Instead, optional **monitoring is done in software**: the tapped
/// buffers are scheduled on a player node that runs through the effects chain to
/// the output. This keeps recording rock-solid and decouples monitoring from the
/// input IO entirely.
@MainActor
final class AudioEngineController: ObservableObject {
    /// Recreated before each capture so `inputNode` binds to the *currently*
    /// selected input device. A live AVAudioEngine on macOS does not rebind its
    /// input when the default device changes, so reusing one instance would keep
    /// capturing the launch-time device (e.g. built-in) even after the user picks
    /// the iPhone / a USB mic. A fresh engine always follows the new default.
    private(set) var engine = AVAudioEngine()
    private let sessionManager: AudioSessionManager
    private var chain: ProcessingChain?
    private var cancellables = Set<AnyCancellable>()

    /// Consumers of raw input buffers (recording writer, waveform sampler).
    private var inputConsumers: [String: (AVAudioPCMBuffer, AVAudioTime) -> Void] = [:]
    private var tapInstalled = false

    /// Player that re-plays tapped input through the effects for monitoring.
    private let monitorPlayer = AVAudioPlayerNode()
    private static let monitorConsumerKey = "monitor"

    /// Virtual mobile-mic capture source (set by `AppEnvironment`). When the user
    /// selects "📱 iPhone (Wi-Fi)", capture taps this stream instead of hardware.
    weak var mobileCaptureSource: StreamInputNode?
    /// The stream source feeds this mixer so the tap sits on a stable node.
    private let captureMixer = AVAudioMixerNode()
    /// The node currently carrying the input tap (hardware input or capture mixer).
    private var tappedNode: AVAudioNode?

    /// Backing playback (existing project tracks) heard while overdubbing.
    private struct BackingItem {
        let player: AVAudioPlayerNode; let file: AVAudioFile
        let timelineStart: AVAudioFramePosition; let sourceIn: AVAudioFramePosition
        let frames: AVAudioFramePosition; let rate: Double
        let trackID: UUID
    }
    private var backingItems: [BackingItem] = []
    /// Which backing tracks are audible during the take (live-switchable).
    private var backingScope: MonitorScope = .all
    private var backingProject: Project?
    private var backingFrom: AVAudioFramePosition = 0

    // MARK: Live Audience / Majlis atmosphere engine
    //
    // A looping crowd ambience bed plays to the output (heard live, NOT captured
    // — the mic tap is separate), and is auto-ducked by an envelope follower
    // keyed off the input tap. AVAudioEngine's dynamics processor has no external
    // sidechain, so this follower-from-the-tap is the correct way to sidechain on
    // this stack: fast attack when the reciter is speaking, slow swell-back on the
    // configured release when they pause.
    private let crowdPlayer = AVAudioPlayerNode()
    private let crowdMixer = AVAudioMixerNode()
    private var crowdBuffer: AVAudioPCMBuffer?
    private var crowdWired = false
    private static let duckConsumerKey = "audienceDuck"

    /// Master switch for the crowd lane (rebuild the graph when toggled).
    var audienceModeEnabled = false
    /// Base crowd-bed level (0...1) before ducking. Live-adjustable.
    var crowdVolume: Float = 0.6
    /// Attenuation applied to the crowd while the reciter is active (dB, negative).
    var duckAmountDb: Float = -9
    /// How quickly the crowd swells back when the reciter pauses (seconds).
    var duckReleaseSeconds: Double = 1.7
    /// Input peak above which the reciter is considered "active" (sensitivity).
    var duckThreshold: Float = 0.04
    /// Smoothed duck gain currently applied (1 = no duck). Audio-thread state.
    private var duckGain: Float = 1.0

    @Published private(set) var isRunning = false
    @Published var isMonitoringEnabled = false {
        didSet {
            guard monitoringWired else { return }
            engine.mainMixerNode.outputVolume = isMonitoringEnabled ? 1 : 0
        }
    }

    /// The format of the raw input signal (hardware-derived).
    private(set) var inputFormat: AVAudioFormat?

    /// Whether the input→effects→mainMixer monitoring path is currently built.
    private var monitoringWired = false

    init(sessionManager: AudioSessionManager) {
        self.sessionManager = sessionManager
        observeSession()
    }

    private func observeSession() {
        sessionManager.configurationChanged
            .sink { [weak self] in self?.handleConfigurationChange() }
            .store(in: &cancellables)
        sessionManager.shouldPause
            .sink { [weak self] in self?.stop() }
            .store(in: &cancellables)
    }

    // MARK: Graph setup

    /// (Re)builds the recording graph for the given chain spec.
    ///
    /// Must be called only after the audio session is configured & active,
    /// otherwise the input node reports an invalid format.
    ///
    /// Recording itself needs only a tap on the input node — no input→output
    /// connections — which is robust across devices/sample-rates. The
    /// input→effects→mainMixer **monitoring** path is built only when monitoring
    /// is requested (headphones), because routing the live input through the
    /// output IO unit is what triggers the `isInputConnToConverter` crash when
    /// the hardware rate differs from the graph.
    func prepare(chain spec: EffectChainSpec, monitor: Bool,
                 backing: Project? = nil, from frame: AVAudioFramePosition = 0) {
        teardown()
        backingProject = backing
        backingFrom = frame
        // Rebind to the selected input device by starting from a fresh engine:
        // a new AVAudioEngine's inputNode picks up the *current* default input
        // (which AudioSessionManager.selectInput just set), so switching to the
        // iPhone / a USB mic actually takes effect. We do not poke the I/O units
        // directly (that can silence the output).
        // Resolve the capture source: the Wi-Fi stream (virtual input) or hardware.
        let captureNode: AVAudioNode
        let format: AVAudioFormat
        if sessionManager.useMobileCapture, let stream = mobileCaptureSource {
            engine.attach(stream.sourceNode)
            engine.attach(captureMixer)
            engine.connect(stream.sourceNode, to: captureMixer, format: stream.format)
            // Connect (silent) to the output so the engine pulls the source node —
            // a tap alone won't drive a manual source. Monitoring, if enabled, is
            // the separate monitorPlayer path.
            engine.connect(captureMixer, to: engine.mainMixerNode, format: stream.format)
            captureMixer.outputVolume = 0
            // Tap the SOURCE node, not the muted mixer — a mixer tap captures the
            // post-volume (zeroed) output, which would record silence.
            captureNode = stream.sourceNode
            format = stream.format
        } else {
            if !engine.isRunning { engine = AVAudioEngine() }   // rebind to current default input
            let input = engine.inputNode
            var f = input.outputFormat(forBus: 0)
            // A Continuity mic can briefly report 0 channels right after selection;
            // give it a moment to warm up rather than silently recording nothing.
            if f.channelCount == 0 || f.sampleRate == 0 {
                for _ in 0..<10 where f.channelCount == 0 || f.sampleRate == 0 {
                    Thread.sleep(forTimeInterval: 0.05)
                    f = input.outputFormat(forBus: 0)
                }
            }
            captureNode = input
            format = f
        }
        guard format.channelCount > 0, format.sampleRate > 0 else {
            inputFormat = nil
            return
        }
        inputFormat = format

        if monitor {
            // Software monitor: tapped input buffers are scheduled on a player
            // that feeds the effects → output. The input node itself is NOT in
            // the output graph, so no converter is forced onto it.
            let processingFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,
                                                 channels: 2) ?? format
            engine.attach(monitorPlayer)
            let newChain = ProcessingChain(spec: spec)
            let chainOutput = newChain.install(into: engine,
                                               source: monitorPlayer,
                                               sourceFormat: format,
                                               processingFormat: processingFormat)
            engine.connect(chainOutput, to: engine.mainMixerNode, format: processingFormat)
            self.chain = newChain
            engine.mainMixerNode.outputVolume = 1
            monitoringWired = true

            // Feed copies of the tapped buffers to the monitor player.
            addInputConsumer(Self.monitorConsumerKey) { [weak self] buffer, _ in
                guard let self, let copy = buffer.deepCopy() else { return }
                self.monitorPlayer.scheduleBuffer(copy, completionHandler: nil)
            }
        } else {
            monitoringWired = false
        }

        // Backing tracks (overdub): play existing project clips to the output so
        // the user hears them while recording. Mic capture is unaffected (it's a
        // separate tap), so the backing isn't in the recording — use headphones
        // to avoid acoustic bleed.
        if let backing {
            var files: [UUID: AVAudioFile] = [:]
            for track in backing.tracks where backing.isAudible(track) {
                for clip in track.clips where clip.frameLength > 0 {
                    let file: AVAudioFile
                    if let cached = files[clip.sourceID] { file = cached }
                    else if let src = backing.source(for: clip.sourceID),
                            let opened = try? AVAudioFile(forReading: src.url) {
                        file = opened; files[clip.sourceID] = opened
                    } else { continue }
                    let player = AVAudioPlayerNode()
                    engine.attach(player)
                    engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
                    backingItems.append(BackingItem(player: player, file: file,
                                                    timelineStart: clip.timelineStartFrame,
                                                    sourceIn: clip.sourceInFrame,
                                                    frames: clip.frameLength,
                                                    rate: file.processingFormat.sampleRate,
                                                    trackID: track.id))
                }
            }
            if !backingItems.isEmpty { engine.mainMixerNode.outputVolume = 1 }   // ensure audible
        }

        if audienceModeEnabled { wireCrowdLane() }

        installInputTapIfNeeded(on: captureNode, format: format)
        engine.prepare()
    }

    /// Attaches the crowd ambience player + its ducking mixer and installs the
    /// envelope-follower consumer on the input tap.
    private func wireCrowdLane() {
        guard let buffer = loadCrowdBuffer() else { return }
        duckGain = 1.0
        engine.attach(crowdPlayer)
        engine.attach(crowdMixer)
        engine.connect(crowdPlayer, to: crowdMixer, format: buffer.format)
        engine.connect(crowdMixer, to: engine.mainMixerNode, format: buffer.format)
        crowdMixer.outputVolume = crowdVolume
        engine.mainMixerNode.outputVolume = 1   // crowd must be audible even without monitoring
        crowdWired = true

        // Envelope-follower ducking, evaluated per input buffer on the audio thread.
        addInputConsumer(Self.duckConsumerKey) { [weak self] pcm, _ in
            guard let self, let ch = pcm.floatChannelData?[0] else { return }
            let frames = vDSP_Length(pcm.frameLength)
            guard frames > 0 else { return }
            var peak: Float = 0
            vDSP_maxmgv(ch, 1, &peak, frames)

            let reciting = peak > self.duckThreshold
            let target: Float = reciting ? pow(10, self.duckAmountDb / 20) : 1.0
            // Fast attack to duck down; slow (configurable) release to swell up.
            let dt = Double(pcm.frameLength) / max(1, pcm.format.sampleRate)
            let tau = target < self.duckGain ? 0.05 : self.duckReleaseSeconds
            let coeff = Float(1 - exp(-dt / tau))
            self.duckGain += (target - self.duckGain) * coeff
            self.crowdMixer.outputVolume = self.crowdVolume * self.duckGain
        }
    }

    private func loadCrowdBuffer() -> AVAudioPCMBuffer? {
        if let crowdBuffer { return crowdBuffer }
        guard let url = Bundle.main.url(forResource: "MajlisCrowd", withExtension: "wav")
                ?? Bundle.main.url(forResource: "MajlisCrowd", withExtension: "wav", subdirectory: "Audio"),
              let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        crowdBuffer = buf
        return buf
    }

    /// Live crowd-level update (no rebuild needed).
    func setCrowdVolume(_ v: Float) {
        crowdVolume = max(0, min(v, 1))
        if crowdWired { crowdMixer.outputVolume = crowdVolume * duckGain }
    }

    private func installInputTapIfNeeded(on node: AVAudioNode, format: AVAudioFormat) {
        guard !tapInstalled else { return }
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, when in
            guard let self else { return }
            // Tap runs on the audio thread — fan out to consumers only.
            for consumer in self.inputConsumers.values { consumer(buffer, when) }
        }
        tappedNode = node
        tapInstalled = true
    }

    func addInputConsumer(_ key: String, _ block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        inputConsumers[key] = block
    }

    func removeInputConsumer(_ key: String) {
        inputConsumers.removeValue(forKey: key)
    }

    // MARK: Run control

    func start() throws {
        guard !engine.isRunning else { isRunning = true; return }
        try engine.start()
        if monitoringWired { monitorPlayer.play() }
        // Schedule + start backing clips relative to the record start position.
        for item in backingItems {
            let end = item.timelineStart + item.frames
            guard end > backingFrom else { continue }
            let skip = max(0, backingFrom - item.timelineStart)
            let framesToPlay = item.frames - skip
            guard framesToPlay > 0 else { continue }
            let when = AVAudioTime(sampleTime: item.timelineStart + skip - backingFrom, atRate: item.rate)
            item.player.scheduleSegment(item.file, startingFrame: item.sourceIn + skip,
                                        frameCount: AVAudioFrameCount(framesToPlay), at: when)
            item.player.play()
        }
        // Loop the crowd ambience bed for the duration of the session.
        if crowdWired, let buffer = crowdBuffer {
            crowdPlayer.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            crowdPlayer.play()
        }
        applyBackingScope()       // honor "hear all / none / one track"
        isRunning = true
    }

    /// Live-switch which backing tracks are audible while recording, without
    /// disturbing the mic capture (just toggles backing player volumes).
    func setMonitorScope(_ scope: MonitorScope) {
        backingScope = scope
        applyBackingScope()
    }

    private func applyBackingScope() {
        for item in backingItems {
            let audible: Bool
            switch backingScope {
            case .all:           audible = true
            case .none:          audible = false
            case .track(let id): audible = item.trackID == id
            }
            item.player.volume = audible ? 1 : 0
        }
    }

    func stop() {
        // Fully release the input tap and IO so the playback engine can bind to
        // the audio session (otherwise it starts with a null session, -10879,
        // and renders no audio).
        teardown()
        isRunning = false
    }

    private func teardown() {
        if tapInstalled {
            tappedNode?.removeTap(onBus: 0)
            tappedNode = nil
            tapInstalled = false
        }
        // Detach the mobile-stream capture nodes if they were attached.
        if engine.attachedNodes.contains(captureMixer) { engine.detach(captureMixer) }
        if let s = mobileCaptureSource, engine.attachedNodes.contains(s.sourceNode) { engine.detach(s.sourceNode) }
        removeInputConsumer(Self.monitorConsumerKey)
        if monitorPlayer.isPlaying { monitorPlayer.stop() }
        if engine.attachedNodes.contains(monitorPlayer) { engine.detach(monitorPlayer) }
        for item in backingItems {
            if item.player.isPlaying { item.player.stop() }
            if engine.attachedNodes.contains(item.player) { engine.detach(item.player) }
        }
        backingItems.removeAll()
        // Tear down the crowd lane + its ducking consumer.
        removeInputConsumer(Self.duckConsumerKey)
        if crowdPlayer.isPlaying { crowdPlayer.stop() }
        if engine.attachedNodes.contains(crowdPlayer) { engine.detach(crowdPlayer) }
        if engine.attachedNodes.contains(crowdMixer) { engine.detach(crowdMixer) }
        crowdWired = false
        engine.stop()
        chain = nil
        monitoringWired = false
    }

    /// Round-trip capture latency in frames, for time-aligning overdub takes.
    /// Combines audio-session I/O latency (incl. Bluetooth) with the engine's
    /// node presentation latency. Query while the engine is running.
    func captureLatencyFrames(sampleRate: Double) -> AVAudioFramePosition {
        var seconds = sessionManager.ioLatencySeconds
        let nodeLatency = engine.outputNode.presentationLatency + engine.inputNode.presentationLatency
        if nodeLatency > 0 { seconds += nodeLatency }
        if seconds <= 0 { seconds = 0.015 }   // sensible fallback (~15 ms)
        return AVAudioFramePosition((seconds * sampleRate).rounded())
    }

    // MARK: Live parameter updates

    func updateChain(_ spec: EffectChainSpec) { chain?.update(spec: spec) }
    func setWetDry(_ value: Float) { chain?.setWetDry(value) }
    func setIntensity(_ value: Float) { chain?.setIntensity(value) }

    // MARK: Config-change recovery

    private func handleConfigurationChange() {
        guard let spec = chain?.spec else { return }
        let wasRunning = engine.isRunning
        prepare(chain: spec, monitor: monitoringWired, backing: backingProject, from: backingFrom)
        if wasRunning { try? start() }
    }

}

extension AVAudioPCMBuffer {
    /// An independent copy safe to schedule on a player (the tap reuses its
    /// buffer storage, so the data must be owned before scheduling).
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        let frames = Int(frameLength)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
        }
        return copy
    }
}
