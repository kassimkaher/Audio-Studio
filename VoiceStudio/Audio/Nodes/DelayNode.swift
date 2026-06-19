import Foundation
import AVFoundation

/// Echo / delay stage backed by `AVAudioUnitDelay`. Feedback produces the
/// successive repeats that emulate the acoustic bounce of large spaces, which is
/// a robust stand-in for a hand-built parallel multi-tap bank. Serves both the
/// `multiTapDelay` (Qur'an echo) and `stereoDelay` (singer slap) kinds.
final class DelayNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind
    var displayName: String { kind.displayName }
    var isEnabled: Bool = true {
        didSet { delay.wetDryMix = isEnabled ? currentMix : 0 }
    }

    private let delay = AVAudioUnitDelay()
    private var currentMix: Float = 20

    init(id: UUID = UUID(), kind: EffectKind) {
        self.id = id
        self.kind = kind
    }

    var avNodes: [AVAudioNode] { [delay] }
    func attach(to engine: AVAudioEngine, format: AVAudioFormat) { engine.attach(delay) }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        let scale = max(0.3, min(intensity, 1.4))
        delay.delayTime = Double(spec.param(ParamKeys.time, default: 0.25))

        // Number of audible repeats maps to feedback. More taps → more feedback.
        let taps = spec.param(ParamKeys.taps, default: kind == .multiTapDelay ? 3 : 1)
        let baseFeedback = spec.param(ParamKeys.feedback, default: 0.2)
        let feedback = min(0.85, baseFeedback + Float(max(0, taps - 1)) * 0.08)
        delay.feedback = feedback * 100 * scale

        delay.lowPassCutoff = 8_000   // tame repeats so they don't muddy articulation
        currentMix = min(100, spec.param(ParamKeys.mix, default: 0.2) * 100 * scale)
        delay.wetDryMix = isEnabled ? currentMix : 0
    }
}
