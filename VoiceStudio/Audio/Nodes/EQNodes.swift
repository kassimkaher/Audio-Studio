import Foundation
import AVFoundation

/// Steep low-cut / high-pass to remove rumble. Two cascaded high-pass bands give
/// a usable slope around the 80–100 Hz target.
final class HighPassNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind = .highPass
    let displayName = EffectKind.highPass.displayName
    var isEnabled: Bool = true {
        didSet { eq.bypass = !isEnabled }
    }

    private let eq = AVAudioUnitEQ(numberOfBands: 2)

    init(id: UUID = UUID()) {
        self.id = id
        for band in eq.bands {
            band.filterType = .highPass
            band.bypass = false
        }
    }

    var avNodes: [AVAudioNode] { [eq] }
    func attach(to engine: AVAudioEngine, format: AVAudioFormat) { engine.attach(eq) }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        let freq = spec.param(ParamKeys.frequency, default: 90)
        for band in eq.bands {
            band.frequency = max(20, min(freq, 500))
            band.bandwidth = 0.5
        }
        eq.bypass = !isEnabled
    }
}

/// High-cut / low-pass to tame harsh or hissy highs.
final class LowPassNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind = .lowPass
    let displayName = EffectKind.lowPass.displayName
    var isEnabled: Bool = true { didSet { eq.bypass = !isEnabled } }

    private let eq = AVAudioUnitEQ(numberOfBands: 1)

    init(id: UUID = UUID()) {
        self.id = id
        eq.bands[0].filterType = .lowPass
        eq.bands[0].bypass = false
    }

    var avNodes: [AVAudioNode] { [eq] }
    func attach(to engine: AVAudioEngine, format: AVAudioFormat) { engine.attach(eq) }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        eq.bands[0].frequency = max(2000, min(spec.param(ParamKeys.frequency, default: 16000), 20000))
        eq.bands[0].bandwidth = 0.5
        eq.bypass = !isEnabled
    }
}

/// Parametric EQ shaping warmth (~250 Hz), presence (~4 kHz) and air (12 kHz shelf).
final class ParametricEQNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind = .parametricEQ
    let displayName = EffectKind.parametricEQ.displayName
    var isEnabled: Bool = true { didSet { eq.bypass = !isEnabled } }

    private let eq = AVAudioUnitEQ(numberOfBands: 3)

    init(id: UUID = UUID()) {
        self.id = id
        let warmth = eq.bands[0]
        warmth.filterType = .parametric
        warmth.frequency = 250
        warmth.bandwidth = 1.0

        let presence = eq.bands[1]
        presence.filterType = .parametric
        presence.frequency = 4000
        presence.bandwidth = 1.2

        let air = eq.bands[2]
        air.filterType = .highShelf
        air.frequency = 12000

        eq.bands.forEach { $0.bypass = false }
    }

    var avNodes: [AVAudioNode] { [eq] }
    func attach(to engine: AVAudioEngine, format: AVAudioFormat) { engine.attach(eq) }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        eq.bands[0].gain = spec.param(ParamKeys.warmthGain, default: 0)
        eq.bands[1].gain = spec.param(ParamKeys.presenceGain, default: 0) * clampedIntensity(intensity)
        eq.bands[2].gain = spec.param(ParamKeys.airGain, default: 0) * clampedIntensity(intensity)
        eq.bypass = !isEnabled
    }

    private func clampedIntensity(_ i: Float) -> Float { max(0.3, min(i, 1.5)) }
}

/// De-esser approximated by a narrow parametric cut in the sibilance band.
/// (Native AVFoundation has no true dynamic de-esser; a static notch is the
/// pragmatic Phase-1 bridge — a custom AUv3 sidechain is the Phase-2 upgrade.)
final class DeEsserNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind = .deEsser
    let displayName = EffectKind.deEsser.displayName
    var isEnabled: Bool = true { didSet { eq.bypass = !isEnabled } }

    private let eq = AVAudioUnitEQ(numberOfBands: 1)

    init(id: UUID = UUID()) {
        self.id = id
        let band = eq.bands[0]
        band.filterType = .parametric
        band.bandwidth = 0.4
        band.bypass = false
    }

    var avNodes: [AVAudioNode] { [eq] }
    func attach(to engine: AVAudioEngine, format: AVAudioFormat) { engine.attach(eq) }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        let band = eq.bands[0]
        band.frequency = spec.param(ParamKeys.deEssFrequency, default: 6500)
        band.gain = spec.param(ParamKeys.deEssAmount, default: -4)
        eq.bypass = !isEnabled
    }
}
