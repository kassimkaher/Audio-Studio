import Foundation
import AVFoundation
import Combine

/// Captures the raw microphone signal to a 24-bit/48 kHz WAV while monitoring
/// through the live effects chain. Returns an `AudioSource` describing the file.
@MainActor
final class RecordingService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isMonitoring = false
    @Published private(set) var elapsedTime: TimeInterval = 0

    /// Drives the live input visualization (fed continuously while monitoring).
    let waveform = WaveformSampler()

    private let engineController: AudioEngineController
    private let sessionManager: AudioSessionManager

    private var writer: RecordingWriter?
    private var fileName: String?
    private var timer: Timer?
    private static let recordKey = "recording"
    private static let meterKey = "meter"

    /// Set when the last take was recorded over a backing track (overdub) and the
    /// measured round-trip latency to time-align it. Consumed on Approve.
    private(set) var lastWasOverdub = false
    private(set) var lastLatencyFrames: AVAudioFramePosition = 0

    init(engineController: AudioEngineController, sessionManager: AudioSessionManager) {
        self.engineController = engineController
        self.sessionManager = sessionManager
    }

    /// Starts the engine with a live input tap that drives the waveform meter —
    /// without recording to file. Lets the record screen show the incoming voice
    /// (and reflect input-source changes) before/while recording.
    func startMonitoring(chain: EffectChainSpec, monitor: Bool) {
        guard !isMonitoring else {
            engineController.updateChain(chain)
            engineController.isMonitoringEnabled = monitor
            return
        }
        // Activate play-and-record FIRST so the input node reports its true
        // hardware format (otherwise the engine inserts a converter and crashes).
        try? sessionManager.configureForRecording()
        engineController.prepare(chain: chain, monitor: monitor)
        engineController.isMonitoringEnabled = monitor

        waveform.reset()
        waveform.start()
        engineController.addInputConsumer(Self.meterKey) { [weak self] buffer, _ in
            self?.waveform.ingest(buffer)   // audio thread: metering only
        }
        try? engineController.start()
        isMonitoring = true
    }

    /// Turns live (audible) monitoring on/off. When the engine is already
    /// running this rebuilds the graph, because the monitor path only exists if
    /// the engine was prepared with monitoring wired.
    func setMonitoringEnabled(_ on: Bool, chain: EffectChainSpec) {
        guard isMonitoring, !isRecording else {
            engineController.isMonitoringEnabled = on
            return
        }
        engineController.prepare(chain: chain, monitor: on)   // meter consumer persists
        engineController.isMonitoringEnabled = on
        try? engineController.start()
    }

    /// Toggles the Live Audience crowd lane. Rebuilds the monitor graph so the
    /// crowd player + ducking consumer are (un)wired. No-op mid-recording.
    func setAudienceMode(_ on: Bool, chain: EffectChainSpec) {
        engineController.audienceModeEnabled = on
        guard isMonitoring, !isRecording else { return }
        engineController.prepare(chain: chain, monitor: engineController.isMonitoringEnabled)
        // The meter consumer persists across prepare(); re-add to be safe.
        engineController.addInputConsumer(Self.meterKey) { [weak self] buffer, _ in
            self?.waveform.ingest(buffer)
        }
        try? engineController.start()
    }

    /// Stops the live input tap and engine (when not recording).
    func stopMonitoring() {
        engineController.removeInputConsumer(Self.meterKey)
        waveform.stop()
        isMonitoring = false
        if !isRecording { engineController.stop() }
    }

    /// Begins recording to file. If `backing` is supplied (overdub), the engine
    /// is (re)built to also play those existing tracks so the user hears them
    /// while recording — captured audio stays clean (separate input tap).
    func start(chain: EffectChainSpec, monitor: Bool,
               backing: Project? = nil, from frame: AVAudioFramePosition = 0) throws {
        guard !isRecording else { return }
        lastWasOverdub = backing != nil

        if backing != nil {
            // Rebuild the engine with backing playback wired in.
            try? sessionManager.configureForRecording()
            engineController.removeInputConsumer(Self.meterKey)
            engineController.prepare(chain: chain, monitor: monitor, backing: backing, from: frame)
            engineController.isMonitoringEnabled = monitor
            waveform.reset(); waveform.start()
            engineController.addInputConsumer(Self.meterKey) { [weak self] buffer, _ in
                self?.waveform.ingest(buffer)
            }
            isMonitoring = true
        } else if !isMonitoring {
            startMonitoring(chain: chain, monitor: monitor)
        } else {
            engineController.isMonitoringEnabled = monitor
        }

        guard let format = engineController.inputFormat else {
            throw RecordingError.noInputFormat
        }
        let name = "rec-\(Int(Date().timeIntervalSince1970)).wav"
        let url = AppPaths.recordingsDirectory.appendingPathComponent(name)
        let writer = try RecordingWriter(url: url, sourceFormat: format)
        self.writer = writer
        self.fileName = name

        engineController.addInputConsumer(Self.recordKey) { [weak self] buffer, _ in
            self?.writer?.write(buffer)     // audio thread: write only
        }
        if backing != nil { try? engineController.start() }   // start engine with backing
        isRecording = true
        elapsedTime = 0
        startTimer()
    }

    /// Stops recording (keeps the engine/metering running) and returns the take.
    @discardableResult
    func stop() -> AudioSource? {
        guard isRecording else { return nil }
        isRecording = false
        stopTimer()
        // Measure round-trip latency while the engine is still running (for
        // overdub time-alignment), in the recording's own sample rate.
        if let sr = engineController.inputFormat?.sampleRate {
            lastLatencyFrames = engineController.captureLatencyFrames(sampleRate: sr)
        }
        engineController.removeInputConsumer(Self.recordKey)

        let result = writer?.finish()
        writer = nil
        guard let result, let fileName else { return nil }
        return AudioSource(fileName: fileName,
                           sampleRate: result.sampleRate,
                           frameCount: result.frameCount)
    }

    func cancel() {
        let name = fileName
        _ = stop()
        stopMonitoring()
        if let name {
            try? FileManager.default.removeItem(at: AppPaths.recordingsDirectory.appendingPathComponent(name))
        }
        fileName = nil
    }

    /// Hands ownership of the recorded file to the caller (e.g. after Approve), so
    /// a later `cancel()` on screen-dismiss won't delete the committed take.
    func relinquishFile() { fileName = nil }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let writer = self.writer else { return }
                self.elapsedTime = writer.elapsedSeconds
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

enum RecordingError: LocalizedError {
    case noInputFormat
    var errorDescription: String? {
        switch self {
        case .noInputFormat: return "Could not determine the microphone input format."
        }
    }
}

/// Thread-safe-ish WAV writer. The owning tap is serialized on the audio thread,
/// so a lock guards only the cross-thread reads of progress.
final class RecordingWriter {
    private let file: AVAudioFile
    private let lock = NSLock()
    private var frames: AVAudioFramePosition = 0
    let sampleRate: Double

    init(url: URL, sourceFormat: AVAudioFormat) throws {
        self.sampleRate = sourceFormat.sampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: sourceFormat.channelCount,
            AVLinearPCMBitDepthKey: AudioFormatConstants.bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
    }

    /// Called on the audio thread.
    func write(_ buffer: AVAudioPCMBuffer) {
        do {
            try file.write(from: buffer)
            lock.lock(); frames += AVAudioFramePosition(buffer.frameLength); lock.unlock()
        } catch {
            // Drop on error; recording continues for remaining buffers.
        }
    }

    var elapsedSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    func finish() -> (sampleRate: Double, frameCount: AVAudioFramePosition)? {
        lock.lock(); let total = frames; lock.unlock()
        return (sampleRate, total)
    }
}
