import Foundation
import AVFoundation

/// Reserves the Phase-2 ML voice-conversion slot in the chain.
///
/// In Phase 1 it is a transparent mixer (unity gain) so ordering, UI and
/// serialization already account for the slot. Phase 2 replaces this conformer
/// with an `MLVoiceConversionNode` that exposes a `renderBlock` bridging CoreML
/// inference — no other code changes required.
final class PassthroughNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind = .mlVoiceConversion
    let displayName = EffectKind.mlVoiceConversion.displayName
    var isEnabled: Bool

    private let mixer = AVAudioMixerNode()

    init(id: UUID = UUID(), isEnabled: Bool = false) {
        self.id = id
        self.isEnabled = isEnabled
    }

    var avNodes: [AVAudioNode] { [mixer] }

    func attach(to engine: AVAudioEngine, format: AVAudioFormat) { engine.attach(mixer) }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        // Pass-through: nothing to tune in Phase 1.
    }
}
