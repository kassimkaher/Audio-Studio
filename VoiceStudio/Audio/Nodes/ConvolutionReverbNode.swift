import Foundation
import AVFoundation

/// Convolution reverb: applies a real impulse response (the acoustic fingerprint
/// of a space) to the signal, with a wet/dry mix. Hosts the custom
/// `ConvolutionAudioUnit` (vended pre-warmed by `ConvolutionUnitProvider`, so no
/// run loop is ever pumped on the main thread during a graph build) and
/// loads/swaps IR `.wav`s through `BundleIRProvider` — so the IR can change live
/// without rebuilding the graph.
final class ConvolutionReverbNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind = .convolutionReverb
    let displayName = EffectKind.convolutionReverb.displayName
    var isEnabled: Bool = true { didSet { applyMix() } }

    /// A pre-warmed convolution AU, or a transparent mixer fallback if the pool
    /// is momentarily empty (chain still works, just without the space).
    private let unit: AVAudioNode = ConvolutionUnitProvider.shared.take() ?? AVAudioMixerNode()
    private let provider: ImpulseResponseProviding
    private var sampleRate: Double = 48_000
    private var loadedIRID: String?
    private var currentMix: Float = 0.45

    private var convAU: ConvolutionAudioUnit? { (unit as? AVAudioUnit)?.auAudioUnit as? ConvolutionAudioUnit }
    /// Offline export keeps the full IR (no real-time cap); live playback caps it.
    private let offline: Bool

    init(id: UUID = UUID(), provider: ImpulseResponseProviding = BundleIRProvider.shared, offline: Bool = false) {
        ConvolutionRegistry.registerIfNeeded()
        self.id = id
        self.provider = provider
        self.offline = offline
    }

    var avNodes: [AVAudioNode] { [unit] }
    func attach(to engine: AVAudioEngine, format: AVAudioFormat) {
        sampleRate = format.sampleRate
        engine.attach(unit)
    }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        currentMix = spec.param(ParamKeys.mix, default: 0.45) * max(0.3, min(intensity, 1.4))
        applyMix()

        let irID = spec.stringParams?[ParamKeys.ir] ?? provider.available.first?.id
        if let irID, irID != loadedIRID {
            if let samples = provider.samples(for: irID, sampleRate: sampleRate) {
                convAU?.capIRTaps = offline ? .max : DirectConvolver.realtimeIRTaps
                convAU?.setIR(samples)
                loadedIRID = irID
            }
        }
    }

    private func applyMix() {
        convAU?.mix = isEnabled ? min(1, currentMix) : 0
    }
}

/// Registers the custom convolution Audio Unit subclass once.
enum ConvolutionRegistry {
    static let description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCC("Cnv1"),
        componentManufacturer: fourCC("Vstd"),
        componentFlags: 0, componentFlagsMask: 0)

    private static var registered = false
    static func registerIfNeeded() {
        guard !registered else { return }
        AUAudioUnit.registerSubclass(ConvolutionAudioUnit.self, as: description,
                                     name: "VoiceStudio Convolution", version: 1)
        registered = true
    }

    private static func fourCC(_ s: String) -> OSType {
        var result: OSType = 0
        for ch in s.unicodeScalars.prefix(4) { result = (result << 8) + (OSType(ch.value) & 0xFF) }
        return result
    }
}

/// Pre-instantiates convolution audio units asynchronously (off the event loop)
/// and vends them synchronously. This avoids ever running a nested run loop on
/// the main thread during a graph build (which can re-enter AppKit event
/// dispatch and crash). If the pool is momentarily empty the node falls back to
/// a passthrough mixer.
final class ConvolutionUnitProvider: @unchecked Sendable {
    static let shared = ConvolutionUnitProvider()
    private let lock = NSLock()
    private var ready: [AVAudioUnit] = []
    private var warming = 0
    private let target = 4

    /// Kick off background instantiation at app launch.
    func warmUp() { refill() }

    /// Returns a ready unit (and refills in the background), or nil if none yet.
    func take() -> AVAudioUnit? {
        lock.lock()
        let unit = ready.isEmpty ? nil : ready.removeLast()
        lock.unlock()
        refill()
        return unit
    }

    private func refill() {
        lock.lock()
        let need = target - ready.count - warming
        if need <= 0 { lock.unlock(); return }
        warming += need
        lock.unlock()
        ConvolutionRegistry.registerIfNeeded()
        for _ in 0..<need {
            AVAudioUnit.instantiate(with: ConvolutionRegistry.description, options: []) { [weak self] unit, _ in
                guard let self else { return }
                self.lock.lock()
                self.warming -= 1
                if let unit { self.ready.append(unit) }
                self.lock.unlock()
            }
        }
    }
}
