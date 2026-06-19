import Foundation
import AVFoundation
import Combine

/// Multi-track timeline playback with **per-clip** effects.
///
/// Routing per track: each clip gets its own player and (optional) clip effect
/// chain, all summed into a track mixer, which runs through the track's master
/// chain and a gain mixer to the main output:
///
///   clip player → [clip chain?] ─┐
///                                ├─ trackSumMixer → [track master chain] → gainMixer → main
///   clip player → [clip chain?] ─┘
@MainActor
final class PlaybackService: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentFrame: AVAudioFramePosition = 0

    private let sessionManager: AudioSessionManager
    /// Recreated per play so the graph is always clean (no accumulated nodes).
    private var engine = AVAudioEngine()

    private struct ClipNode {
        let player: AVAudioPlayerNode
        let clip: Clip
        let sourceRate: Double
    }
    private struct TrackGraph {
        let sumMixer: AVAudioMixerNode
        let masterChain: ProcessingChain
        let gainMixer: AVAudioMixerNode
        var clipNodes: [ClipNode]
    }
    private var trackGraphs: [UUID: TrackGraph] = [:]
    private var clipChains: [UUID: ProcessingChain] = [:]   // clipID → chain (live updates)
    private var openFiles: [UUID: AVAudioFile] = [:]   // sourceID → file
    private var leadPlayer: AVAudioPlayerNode?
    private var project: Project?
    private var startFrame: AVAudioFramePosition = 0
    private var timer: Timer?
    private var autoStopWork: DispatchWorkItem?
    private var loop = false
    /// The record/monitor engine — released before playback so the audio session
    /// can route output correctly (it otherwise holds play-and-record mode).
    weak var recordEngine: AudioEngineController?

    init(sessionManager: AudioSessionManager) {
        self.sessionManager = sessionManager
    }

    // MARK: Transport

    func play(project: Project, from frame: AVAudioFramePosition, loop: Bool = false) {
        stop()
        guard project.totalFrames > 0 else { return }
        self.project = project
        self.startFrame = frame
        self.loop = loop

        do {
            recordEngine?.stop()                     // free the input/monitor engine + session
            engine = AVAudioEngine()                 // fresh, clean graph each time
            try sessionManager.configureForPlayback()
            buildGraph(for: project)
            engine.prepare()
            try engine.start()
            scheduleClips(from: frame)
            startAllPlayers()
            isPlaying = true
            startTimer()
            scheduleAutoStop(project: project, from: frame)
        } catch {
            stop()
        }
    }

    /// Plays a single clip through its own per-clip effects (for the inspector /
    /// record preview). Reuses the full transport by wrapping the clip in a tiny
    /// throwaway project with an empty track master chain. `loop` keeps it
    /// repeating so filter edits can be auditioned hands-free.
    func previewClip(_ clip: Clip, source: AudioSource, loop: Bool = false) {
        var c = clip
        c.timelineStartFrame = 0
        let track = Track(name: "Preview", kind: .vocal, clips: [c], effectChain: .empty)
        let temp = Project(name: "Preview", sampleRate: source.sampleRate,
                           tracks: [track], sources: [source])
        play(project: temp, from: 0, loop: loop)
    }

    func pause() {
        guard isPlaying else { return }
        autoStopWork?.cancel(); autoStopWork = nil
        allPlayers.forEach { $0.pause() }
        engine.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        loop = false
        autoStopWork?.cancel(); autoStopWork = nil
        stopTimer()
        allPlayers.forEach { $0.stop() }
        if engine.isRunning { engine.stop() }
        teardownGraph()
        isPlaying = false
        currentFrame = 0   // a full stop rewinds to the start
    }

    func seek(to frame: AVAudioFramePosition) {
        currentFrame = max(0, frame)
        if isPlaying, let project { play(project: project, from: currentFrame) }
    }

    private var allPlayers: [AVAudioPlayerNode] {
        trackGraphs.values.flatMap { $0.clipNodes.map(\.player) }
    }

    private func scheduleAutoStop(project: Project, from frame: AVAudioFramePosition) {
        let rate = trackGraphs.values.first?.clipNodes.first?.sourceRate ?? project.sampleRate
        let remaining = max(0, project.totalFrames - frame)
        let seconds = Double(remaining) / max(1, rate) + 0.6   // tail for reverb
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.loop { self.loopRestart() } else { self.stop() }
        }
        autoStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Restarts the current content from the top without rebuilding the engine,
    /// so looped preview keeps playing while filters are being edited.
    private func loopRestart() {
        guard isPlaying, let project else { return }
        allPlayers.forEach { $0.stop() }
        startFrame = 0
        scheduleClips(from: 0)
        startAllPlayers()
        scheduleAutoStop(project: project, from: 0)
    }

    // MARK: Graph

    private func buildGraph(for project: Project) {
        let masterFormat = AVAudioFormat(standardFormatWithSampleRate: project.sampleRate,
                                         channels: AudioFormatConstants.mixdownChannelCount)!
        for track in project.tracks {
            let sumMixer = AVAudioMixerNode()
            let gainMixer = AVAudioMixerNode()
            engine.attach(sumMixer)
            engine.attach(gainMixer)

            var clipNodes: [ClipNode] = []
            for clip in track.clips {
                guard let file = file(for: clip.sourceID, project: project) else { continue }
                let fileFormat = file.processingFormat
                let player = AVAudioPlayerNode()
                engine.attach(player)

                if let clipSpec = clip.effectChain {
                    let proc = AVAudioFormat(standardFormatWithSampleRate: fileFormat.sampleRate,
                                             channels: AudioFormatConstants.mixdownChannelCount) ?? fileFormat
                    let clipChain = ProcessingChain(spec: clipSpec)
                    let out = clipChain.install(into: engine, source: player,
                                                sourceFormat: fileFormat, processingFormat: proc)
                    engine.connect(out, to: sumMixer, format: proc)
                    clipChains[clip.id] = clipChain   // for live parameter updates
                } else {
                    engine.connect(player, to: sumMixer, format: fileFormat)
                }
                clipNodes.append(ClipNode(player: player, clip: clip, sourceRate: fileFormat.sampleRate))
                if leadPlayer == nil { leadPlayer = player }
            }

            // Track master chain over the summed clips.
            let masterChain = ProcessingChain(spec: track.effectChain)
            let masterOut = masterChain.install(into: engine, source: sumMixer,
                                                sourceFormat: masterFormat, processingFormat: masterFormat)
            engine.connect(masterOut, to: gainMixer, format: masterFormat)
            engine.connect(gainMixer, to: engine.mainMixerNode, format: masterFormat)
            gainMixer.outputVolume = project.isAudible(track) ? track.volume : 0

            trackGraphs[track.id] = TrackGraph(sumMixer: sumMixer, masterChain: masterChain,
                                               gainMixer: gainMixer, clipNodes: clipNodes)
        }
    }

    private func teardownGraph() {
        for graph in trackGraphs.values {
            graph.clipNodes.forEach { engine.detach($0.player) }
            engine.detach(graph.sumMixer)
            engine.detach(graph.gainMixer)
        }
        trackGraphs.removeAll()
        clipChains.removeAll()
        openFiles.removeAll()
        leadPlayer = nil
    }

    private func file(for sourceID: UUID, project: Project) -> AVAudioFile? {
        if let f = openFiles[sourceID] { return f }
        guard let source = project.source(for: sourceID),
              let file = try? AVAudioFile(forReading: source.url) else { return nil }
        openFiles[sourceID] = file
        return file
    }

    private func scheduleClips(from frame: AVAudioFramePosition) {
        guard let project else { return }
        for track in project.tracks {
            guard let graph = trackGraphs[track.id] else { continue }
            for node in graph.clipNodes {
                let clip = node.clip
                guard clip.timelineEndFrame > frame,
                      let file = file(for: clip.sourceID, project: project) else { continue }
                let skip = max(0, frame - clip.timelineStartFrame)
                let startInSource = clip.sourceInFrame + skip
                let framesToPlay = clip.frameLength - skip
                guard framesToPlay > 0 else { continue }
                let when = AVAudioTime(sampleTime: clip.timelineStartFrame + skip - frame,
                                       atRate: node.sourceRate)
                node.player.scheduleSegment(file,
                                            startingFrame: startInSource,
                                            frameCount: AVAudioFrameCount(framesToPlay),
                                            at: when)
            }
        }
    }

    private func startAllPlayers() {
        allPlayers.forEach { $0.play() }
    }

    // MARK: Live mix updates

    func applyMix(from project: Project) {
        self.project = project
        for track in project.tracks {
            trackGraphs[track.id]?.gainMixer.outputVolume = project.isAudible(track) ? track.volume : 0
        }
    }

    func updateChain(for trackID: UUID, spec: EffectChainSpec) {
        trackGraphs[trackID]?.masterChain.update(spec: spec)
    }

    /// Live-updates a clip's per-clip effect parameters while it is playing
    /// (so edits are heard without restarting playback). Parameter and bypass
    /// changes apply live; adding/removing a filter still needs a rebuild.
    func updateClipChain(_ clipID: UUID, spec: EffectChainSpec) {
        clipChains[clipID]?.update(spec: spec)
    }

    // MARK: Playhead

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePlayhead() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updatePlayhead() {
        guard let player = leadPlayer,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return }
        currentFrame = startFrame + playerTime.sampleTime
        if !loop, let project, currentFrame >= project.totalFrames { stop() }
    }
}
