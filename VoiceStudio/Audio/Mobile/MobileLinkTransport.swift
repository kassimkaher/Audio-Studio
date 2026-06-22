import Foundation

/// Shared wire constants used by both the Mac host (`BonjourTransport`) and the
/// iOS companion app (`VoiceStudioMic`).
enum MobileLink {
    static let serviceType = "_voicestudiomic._tcp"
    static let port: UInt16 = 8787
}

/// One unit of streamed mono audio from a linked phone.
///
/// Wire format (little-endian): `[UInt32 sequence][UInt32 sampleCount][Float32 × sampleCount]`.
struct AudioFrame: Equatable {
    var sequence: UInt32
    var samples: [Float]            // mono Float32, normalised -1…1

    func encoded() -> Data {
        var data = Data(capacity: 8 + samples.count * 4)
        var seq = sequence.littleEndian
        withUnsafeBytes(of: &seq) { data.append(contentsOf: $0) }
        var count = UInt32(samples.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func decode(_ data: Data) -> AudioFrame? {
        guard data.count >= 8 else { return nil }
        return data.withUnsafeBytes { raw -> AudioFrame? in
            let seq = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            let count = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            guard count >= 0, data.count >= 8 + count * 4 else { return nil }
            var samples = [Float](repeating: 0, count: count)
            for i in 0..<count {
                samples[i] = raw.loadUnaligned(fromByteOffset: 8 + i * 4, as: Float.self)
            }
            return AudioFrame(sequence: seq, samples: samples)
        }
    }
}

/// Connection state of a mobile link, surfaced to the UI.
enum LinkState: Equatable {
    case idle
    case advertising(String)        // endpoint string (IP:port) the phone connects to
    case connected(String)          // linked device name
    case failed(String)
}

/// Abstracts the wire under the mobile mic link. v1 ships `BonjourTransport`
/// (Wi-Fi); a `USBMuxTransport` can be added later without touching anything
/// above this protocol. `SyntheticToneTransport` lets the whole pipeline be
/// exercised and tested with **no phone and no audio hardware**.
protocol MobileLinkTransport: AnyObject {
    var onFrame: ((AudioFrame) -> Void)? { get set }
    var onState: ((LinkState) -> Void)? { get set }
    func start()
    func stop()
}

/// Generates a deterministic sine tone as a stand-in for a streaming phone —
/// used to prove and test the virtual-input pipeline before the network/companion
/// app exist.
final class SyntheticToneTransport: MobileLinkTransport {
    var onFrame: ((AudioFrame) -> Void)?
    var onState: ((LinkState) -> Void)?

    let sampleRate: Double
    let frequency: Double
    let frameSize: Int

    private var phase = 0.0
    private var sequence: UInt32 = 0
    private var thread: Thread?
    private var running = false

    init(sampleRate: Double = 48_000, frequency: Double = 440, frameSize: Int = 480) {
        self.sampleRate = sampleRate
        self.frequency = frequency
        self.frameSize = frameSize
    }

    /// Produces the next tone frame deterministically (exposed for tests).
    func nextFrame() -> AudioFrame {
        var samples = [Float](repeating: 0, count: frameSize)
        let increment = 2 * Double.pi * frequency / sampleRate
        for i in 0..<frameSize {
            samples[i] = Float(sin(phase))
            phase += increment
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
        defer { sequence &+= 1 }
        return AudioFrame(sequence: sequence, samples: samples)
    }

    func start() {
        guard !running else { return }
        running = true
        onState?(.connected("Synthetic Tone"))
        let interval = Double(frameSize) / sampleRate
        let t = Thread { [weak self] in
            while let self, self.running {
                self.onFrame?(self.nextFrame())
                Thread.sleep(forTimeInterval: interval)
            }
        }
        t.name = "SyntheticToneTransport"
        thread = t
        t.start()
    }

    func stop() {
        running = false
        thread = nil
        onState?(.idle)
    }
}
