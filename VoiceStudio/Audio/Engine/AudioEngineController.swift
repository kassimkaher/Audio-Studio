import Foundation
import AVFoundation
import Combine

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
    let engine = AVAudioEngine()
    private let sessionManager: AudioSessionManager
    private var chain: ProcessingChain?
    private var cancellables = Set<AnyCancellable>()

    /// Consumers of raw input buffers (recording writer, waveform sampler).
    private var inputConsumers: [String: (AVAudioPCMBuffer, AVAudioTime) -> Void] = [:]
    private var tapInstalled = false

    /// Player that re-plays tapped input through the effects for monitoring.
    private let monitorPlayer = AVAudioPlayerNode()
    private static let monitorConsumerKey = "monitor"

    /// Backing playback (existing project tracks) heard while overdubbing.
    private struct BackingItem {
        let player: AVAudioPlayerNode; let file: AVAudioFile
        let timelineStart: AVAudioFramePosition; let sourceIn: AVAudioFramePosition
        let frames: AVAudioFramePosition; let rate: Double
    }
    private var backingItems: [BackingItem] = []
    private var backingProject: Project?
    private var backingFrom: AVAudioFramePosition = 0

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
        // macOS device routing is handled via the system default device
        // (set in AudioSessionManager) — the engine follows it reliably. We do
        // not poke the engine I/O units, which can silence the output.

        let input = engine.inputNode
        // Use the node's output format (post-session) for both connection and tap.
        let format = input.outputFormat(forBus: 0)
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
                                                    rate: file.processingFormat.sampleRate))
                }
            }
            if !backingItems.isEmpty { engine.mainMixerNode.outputVolume = 1 }   // ensure audible
        }

        installInputTapIfNeeded(format: format)
        engine.prepare()
    }

    private func installInputTapIfNeeded(format: AVAudioFormat) {
        guard !tapInstalled else { return }
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, when in
            guard let self else { return }
            // Tap runs on the audio thread — fan out to consumers only.
            for consumer in self.inputConsumers.values { consumer(buffer, when) }
        }
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
        isRunning = true
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
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        removeInputConsumer(Self.monitorConsumerKey)
        if monitorPlayer.isPlaying { monitorPlayer.stop() }
        if engine.attachedNodes.contains(monitorPlayer) { engine.detach(monitorPlayer) }
        for item in backingItems {
            if item.player.isPlaying { item.player.stop() }
            if engine.attachedNodes.contains(item.player) { engine.detach(item.player) }
        }
        backingItems.removeAll()
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
