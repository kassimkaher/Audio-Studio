import Foundation

/// The sonic "fingerprint" extracted from a reference recording — the output of
/// the Reference Style Transfer analysis. Stored so a saved Mode can reproduce a
/// reference track's tonal balance and acoustic space.
struct VoiceProfile: Codable, Hashable {
    /// Target EQ response as (frequency Hz, gain dB) points.
    struct EQPoint: Codable, Hashable { let frequency: Double; let gain: Double }

    var eqCurve: [EQPoint]
    /// The id of the best-matching bundled impulse response.
    var referenceIRIdentifier: String
    /// Convolution wet/dry mix (0...1) for the matched space.
    var reverbWetDryMix: Double

    static let neutral = VoiceProfile(
        eqCurve: [EQPoint(frequency: 250, gain: 0),
                  EQPoint(frequency: 4000, gain: 0),
                  EQPoint(frequency: 12000, gain: 0)],
        referenceIRIdentifier: "HussainiHall",
        reverbWetDryMix: 0.35)

    /// Converts the profile into a concrete effect chain (so it can be saved as a
    /// Mode and applied to any take). Maps the EQ curve to the parametric EQ and
    /// the IR + wet mix to a convolution stage.
    func makeChain() -> EffectChainSpec {
        var eqParams: [String: Float] = [:]
        for point in eqCurve {
            switch point.frequency {
            case ..<800:      eqParams[ParamKeys.warmthGain] = Float(point.gain)
            case 800..<8000:  eqParams[ParamKeys.presenceGain] = Float(point.gain)
            default:          eqParams[ParamKeys.airGain] = Float(point.gain)
            }
        }
        return EffectChainSpec(stages: [
            EffectStageSpec(kind: .parametricEQ, params: eqParams),
            EffectStageSpec(kind: .convolutionReverb,
                            params: [ParamKeys.mix: Float(reverbWetDryMix)],
                            stringParams: [ParamKeys.ir: referenceIRIdentifier])
        ], wetDryMix: 1.0, intensity: 1.0)
    }
}
