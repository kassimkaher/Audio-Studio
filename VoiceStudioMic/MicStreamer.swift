import Foundation
import Network
import AVFoundation
import os

/// Thread-safe flag/counter for the real-time audio tap (which must not touch the
/// main actor).
private final class AtomicBool {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    var value: Bool {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
private final class SeqCounter {
    private let lock = OSAllocatedUnfairLock(initialState: UInt32(0))
    func next() -> UInt32 { lock.withLock { let v = $0; $0 &+= 1; return v } }
}

/// Captures the iPhone microphone, converts it to 48 kHz mono Float32, and
/// streams length-prefixed `AudioFrame`s to the Mac host it discovers over
/// Bonjour (`_voicestudiomic._tcp`).
@MainActor
final class MicStreamer: ObservableObject {
    enum Status: Equatable {
        case idle, searching, connecting, streaming, denied, error(String)
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var hostName: String?
    @Published var muted = false { didSet { mutedFlag.value = muted } }

    private let mutedFlag = AtomicBool()
    private let seqCounter = SeqCounter()

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let engine = AVAudioEngine()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 48_000, channels: 1, interleaved: false)!
    private let netQueue = DispatchQueue(label: "com.voicestudio.mic.net")

    func start() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else { self.status = .denied; return }
                self.configureSession()
                self.browse()
            }
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        connection?.cancel(); connection = nil
        browser?.cancel(); browser = nil
        status = .idle; hostName = nil
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.allowBluetooth, .defaultToSpeaker])
        try? session.setActive(true)
    }

    // MARK: Discovery

    private func browse() {
        status = .searching
        let browser = NWBrowser(for: .bonjour(type: MobileLink.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let first = results.first else { return }
            Task { @MainActor in
                guard let self, self.connection == nil else { return }
                self.connect(to: first.endpoint)
            }
        }
        browser.start(queue: netQueue)
        self.browser = browser
    }

    private func connect(to endpoint: NWEndpoint) {
        status = .connecting
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.status = .streaming; self.hostName = "Mac"; self.startCapture()
                case .failed(let e):
                    self.status = .error("\(e)"); self.connection = nil
                case .cancelled:
                    self.connection = nil
                default: break
                }
            }
        }
        connection = conn
        conn.start(queue: netQueue)
    }

    // MARK: Capture → stream  (tap closure captures locals only — no `self`)

    private func startCapture() {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.channelCount > 0, let connection else {
            status = .error("No microphone input"); return
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            status = .error("Converter unavailable"); return
        }
        let outFormat = self.outFormat
        let muted = self.mutedFlag
        let seq = self.seqCounter

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buffer, _ in
            guard !muted.value else { return }
            let ratio = outFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var err: NSError?
            let result = converter.convert(to: out, error: &err) { _, inStatus in
                if supplied { inStatus.pointee = .noDataNow; return nil }
                supplied = true; inStatus.pointee = .haveData; return buffer
            }
            guard result != .error, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
            let n = Int(out.frameLength)
            var samples = [Float](repeating: 0, count: n)
            samples.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: ch, count: n) }
            let payload = AudioFrame(sequence: seq.next(), samples: samples).encoded()
            var packet = Data(capacity: payload.count + 4)
            var length = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
            packet.append(payload)
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
        do { try engine.start() } catch { status = .error("\(error)") }
    }
}
