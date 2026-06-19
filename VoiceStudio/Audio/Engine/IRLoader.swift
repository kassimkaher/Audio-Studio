import Foundation
import AVFoundation
import Combine
import Accelerate

/// Identifies a selectable acoustic space (one IR `.wav`).
struct IRDescriptor: Identifiable, Hashable {
    let id: String      // filename stem, e.g. "HussainiHall"
    let name: String    // display name, e.g. "Hussaini Hall"
}

/// Protocol-oriented IR source so the convolution engine never hard-codes files.
protocol ImpulseResponseProviding {
    var available: [IRDescriptor] { get }
    /// Mono IR samples resampled to `sampleRate` (nil if unknown id).
    func samples(for id: String, sampleRate: Double) -> [Float]?
}

/// Discovers IR `.wav` files bundled in the app. Adding/replacing an acoustic
/// space is just dropping a `.wav` into `Resources/IRs/` — no code changes.
final class BundleIRProvider: ImpulseResponseProviding, @unchecked Sendable {
    static let shared = BundleIRProvider()

    private let lock = NSLock()
    private var cache: [String: [Float]] = [:]   // "id@rate" → samples

    private func urls() -> [URL] {
        // Look in an "IRs" subdirectory first, then fall back to bundle root.
        let sub = Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: "IRs") ?? []
        let root = Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: nil) ?? []
        let all = (sub + root).reduce(into: [URL]()) { acc, u in
            if !acc.contains(where: { $0.lastPathComponent == u.lastPathComponent }) { acc.append(u) }
        }
        return all.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var available: [IRDescriptor] {
        urls().map { url in
            let stem = url.deletingPathExtension().lastPathComponent
            return IRDescriptor(id: stem, name: Self.prettify(stem))
        }
    }

    func samples(for id: String, sampleRate: Double) -> [Float]? {
        let key = "\(id)@\(Int(sampleRate))"
        lock.lock(); if let cached = cache[key] { lock.unlock(); return cached }; lock.unlock()

        guard let url = urls().first(where: { $0.deletingPathExtension().lastPathComponent == id }),
              let samples = Self.loadMono(url: url, sampleRate: sampleRate) else { return nil }
        lock.lock(); cache[key] = samples; lock.unlock()
        return samples
    }

    // MARK: Loading + resampling

    private static func loadMono(url: URL, sampleRate: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let srcFormat = file.processingFormat
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                               frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: srcBuffer) } catch { return nil }

        // Convert to mono Float at the target sample rate.
        guard let dstFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            return monoFloat(from: srcBuffer)   // same-rate fallback
        }
        let ratio = sampleRate / srcFormat.sampleRate
        let cap = AVAudioFrameCount(Double(file.length) * ratio + 1024)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: dstBuffer, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return srcBuffer
        }
        if err != nil { return monoFloat(from: srcBuffer) }
        return monoFloat(from: dstBuffer)
    }

    private static func monoFloat(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let ch = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var out = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            let p = ch[c]
            for i in 0..<n { out[i] += p[i] }
        }
        if channels > 1 { var g = 1 / Float(channels); vDSP_vsmul(out, 1, &g, &out, 1, vDSP_Length(n)) }
        return out
    }

    private static func prettify(_ stem: String) -> String {
        // "HussainiHall" → "Hussaini Hall"
        var result = ""
        for (i, ch) in stem.enumerated() {
            if i > 0, ch.isUppercase { result.append(" ") }
            result.append(ch)
        }
        return result
    }
}

/// UI-facing, observable list of available acoustic spaces.
@MainActor
final class IRLoader: ObservableObject {
    @Published private(set) var available: [IRDescriptor]
    let provider: ImpulseResponseProviding

    init(provider: ImpulseResponseProviding = BundleIRProvider.shared) {
        self.provider = provider
        self.available = provider.available
    }

    func refresh() { available = provider.available }
    func name(for id: String) -> String { available.first { $0.id == id }?.name ?? id }
    var defaultID: String? { available.first?.id }
}
