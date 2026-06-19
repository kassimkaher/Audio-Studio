import Foundation
import AVFoundation

/// Algorithmic reverb with an optional series pre-delay used to model the long,
/// majestic decay of large spaces (the "Grand Mosque / Haram" character).
///
/// Native `AVAudioUnitReverb` exposes only factory presets + wet/dry, so true
/// RT60/IR control is a Phase-2 convolution AUv3 upgrade; the pre-delay stage
/// here gives a convincing approximation today.
final class ReverbNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind = .reverb
    let displayName = EffectKind.reverb.displayName
    var isEnabled: Bool = true {
        didSet { reverb.wetDryMix = isEnabled ? currentMix : 0 }
    }

    private let preDelay = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    private var currentMix: Float = 40

    init(id: UUID = UUID()) {
        self.id = id
        reverb.loadFactoryPreset(.cathedral)
        preDelay.feedback = 0
        preDelay.wetDryMix = 100
    }

    var avNodes: [AVAudioNode] { [preDelay, reverb] }
    var inputNode: AVAudioNode { preDelay }
    var outputNode: AVAudioNode { reverb }

    func attach(to engine: AVAudioEngine, format: AVAudioFormat) {
        engine.attach(preDelay)
        engine.attach(reverb)
        engine.connect(preDelay, to: reverb, format: format)   // internal edge
    }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        let presetRaw = Int(spec.param(ParamKeys.reverbPreset, default: Float(AVAudioUnitReverbPreset.cathedral.rawValue)))
        if let preset = AVAudioUnitReverbPreset(rawValue: presetRaw) {
            reverb.loadFactoryPreset(preset)
        }
        let baseMix = spec.param(ParamKeys.mix, default: 0.4) * 100
        currentMix = min(100, baseMix * max(0.3, min(intensity, 1.4)))
        reverb.wetDryMix = isEnabled ? currentMix : 0

        // Pre-delay in ms → seconds. 0 disables the series delay's effect.
        let preMs = spec.param(ParamKeys.preDelay, default: 0)
        preDelay.delayTime = Double(preMs) / 1000.0
        preDelay.wetDryMix = preMs > 0 ? 100 : 0
    }
}
