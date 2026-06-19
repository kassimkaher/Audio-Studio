import Foundation
import AVFoundation

/// Pitch / formant and chorus-doubling stage backed by `AVAudioUnitTimePitch`.
///
/// `.pitch` shifts the whole signal by a number of cents; `.chorus` applies a
/// gentle detune to thicken the voice into a wider, ensemble-like character
/// (the Anasheed "doubling" feel). True formant-preserving conversion and a
/// blended modulated chorus are Phase-2 DSP/ML upgrades — this is the pragmatic
/// native bridge.
final class PitchNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind
    var displayName: String { kind.displayName }
    var isEnabled: Bool = true {
        didSet { unit.bypass = !isEnabled }
    }

    private let unit = AVAudioUnitTimePitch()

    init(id: UUID = UUID(), kind: EffectKind) {
        self.id = id
        self.kind = kind
    }

    var avNodes: [AVAudioNode] { [unit] }
    func attach(to engine: AVAudioEngine, format: AVAudioFormat) { engine.attach(unit) }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        let scale = max(0.3, min(intensity, 1.4))
        // Cents → AVAudioUnitTimePitch.pitch is already in cents.
        let cents = spec.param(ParamKeys.detuneCents, default: kind == .chorus ? 8 : 0)
        unit.pitch = cents * scale
        unit.rate = 1.0
        unit.overlap = 8
        unit.bypass = !isEnabled
    }
}

/// Subtle analog-style warmth via `AVAudioUnitDistortion` at a low wet mix.
final class WarmthNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind = .distortion
    let displayName = EffectKind.distortion.displayName
    var isEnabled: Bool = true { didSet { unit.wetDryMix = isEnabled ? currentMix : 0 } }

    private let unit = AVAudioUnitDistortion()
    private var currentMix: Float = 8

    init(id: UUID = UUID()) {
        self.id = id
        unit.loadFactoryPreset(.drumsBitBrush)
    }

    var avNodes: [AVAudioNode] { [unit] }
    func attach(to engine: AVAudioEngine, format: AVAudioFormat) { engine.attach(unit) }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        unit.preGain = spec.param(ParamKeys.drive, default: -6)
        currentMix = min(40, spec.param(ParamKeys.mix, default: 0.08) * 100 * max(0.3, min(intensity, 1.4)))
        unit.wetDryMix = isEnabled ? currentMix : 0
    }
}
