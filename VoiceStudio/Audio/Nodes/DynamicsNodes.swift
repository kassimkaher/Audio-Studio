import Foundation
import AVFoundation

/// Noise gate implemented as a downward expander via `AVAudioUnitDynamicsProcessor`.
/// Silences background hiss/room tone below the threshold.
final class NoiseGateNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind = .noiseGate
    let displayName = EffectKind.noiseGate.displayName
    var isEnabled: Bool = true { didSet { processor.bypass = !isEnabled } }

    private let processor = AVAudioUnitEffect.makeDynamics()

    init(id: UUID = UUID()) { self.id = id }

    var avNodes: [AVAudioNode] { [processor] }
    func attach(to engine: AVAudioEngine, format: AVAudioFormat) { engine.attach(processor) }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        let au = processor.audioUnit
        let threshold = spec.param(ParamKeys.threshold, default: -48)
        // Strong downward expansion below threshold acts as a gate.
        DynamicsParam.set(au, .expansionThreshold, threshold)
        DynamicsParam.set(au, .expansionRatio, spec.param(ParamKeys.ratio, default: 10))
        DynamicsParam.set(au, .attackTime, spec.param(ParamKeys.attack, default: 0.002))
        DynamicsParam.set(au, .releaseTime, spec.param(ParamKeys.release, default: 0.12))
        // Neutralize the compressor half of the processor.
        DynamicsParam.set(au, .compressionThreshold, 0)
        DynamicsParam.set(au, .headRoom, 5)
        processor.bypass = !isEnabled
    }
}

/// Smooth vocal compressor (low ratio, fast-ish attack) for dynamics control.
final class CompressorNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind = .compressor
    let displayName = EffectKind.compressor.displayName
    var isEnabled: Bool = true { didSet { processor.bypass = !isEnabled } }

    private let processor = AVAudioUnitEffect.makeDynamics()

    init(id: UUID = UUID()) { self.id = id }

    var avNodes: [AVAudioNode] { [processor] }
    func attach(to engine: AVAudioEngine, format: AVAudioFormat) { engine.attach(processor) }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        let au = processor.audioUnit
        DynamicsParam.set(au, .compressionThreshold, spec.param(ParamKeys.threshold, default: -18))
        DynamicsParam.set(au, .compressionHeadRoom, max(0.5, 10 / spec.param(ParamKeys.ratio, default: 3)))
        DynamicsParam.set(au, .attackTime, spec.param(ParamKeys.attack, default: 0.005))
        DynamicsParam.set(au, .releaseTime, spec.param(ParamKeys.release, default: 0.18))
        DynamicsParam.set(au, .masterGain, spec.param(ParamKeys.masterGain, default: 0))
        // Disable the expander half.
        DynamicsParam.set(au, .expansionThreshold, -120)
        processor.bypass = !isEnabled
    }
}

/// Peak limiter — boosts perceived loudness while preventing clipping.
final class LimiterNode: AudioProcessingNode {
    let id: UUID
    let kind: EffectKind = .limiter
    let displayName = EffectKind.limiter.displayName
    var isEnabled: Bool = true { didSet { limiter.bypass = !isEnabled } }

    private let limiter: AVAudioUnitEffect = {
        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Effect
        desc.componentSubType = kAudioUnitSubType_PeakLimiter
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }()

    init(id: UUID = UUID()) { self.id = id }

    var avNodes: [AVAudioNode] { [limiter] }
    func attach(to engine: AVAudioEngine, format: AVAudioFormat) { engine.attach(limiter) }

    func applyParameters(_ spec: EffectStageSpec, intensity: Float) {
        let preGain = spec.param(ParamKeys.preGain, default: 6) * max(0.3, min(intensity, 1.4))
        AudioUnitSetParameter(limiter.audioUnit, AudioUnitParameterID(kLimiterParam_PreGain),
                              kAudioUnitScope_Global, 0, max(-10, min(preGain, 40)), 0)
        limiter.bypass = !isEnabled
    }
}

// MARK: - Dynamics processor helpers

/// Factory + parameter helpers for the (sparsely documented) Apple dynamics AU.
enum AVAudioUnitEffectFactory {}

extension AVAudioUnit {
    /// Convenience builder for the system dynamics processor audio unit.
    static func makeDynamics() -> AVAudioUnitEffect {
        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Effect
        desc.componentSubType = kAudioUnitSubType_DynamicsProcessor
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }
}

/// Strongly-typed wrapper over the dynamics processor's parameter IDs.
enum DynamicsParam {
    case compressionThreshold
    case compressionHeadRoom
    case expansionThreshold
    case expansionRatio
    case attackTime
    case releaseTime
    case masterGain
    case headRoom
    case compressionRatio

    var rawID: AudioUnitParameterID {
        switch self {
        case .compressionThreshold: return AudioUnitParameterID(kDynamicsProcessorParam_Threshold)
        case .compressionHeadRoom: return AudioUnitParameterID(kDynamicsProcessorParam_HeadRoom)
        case .headRoom: return AudioUnitParameterID(kDynamicsProcessorParam_HeadRoom)
        case .expansionThreshold: return AudioUnitParameterID(kDynamicsProcessorParam_ExpansionThreshold)
        case .expansionRatio: return AudioUnitParameterID(kDynamicsProcessorParam_ExpansionRatio)
        case .attackTime: return AudioUnitParameterID(kDynamicsProcessorParam_AttackTime)
        case .releaseTime: return AudioUnitParameterID(kDynamicsProcessorParam_ReleaseTime)
        case .masterGain: return AudioUnitParameterID(kDynamicsProcessorParam_OverallGain)
        case .compressionRatio: return AudioUnitParameterID(kDynamicsProcessorParam_ExpansionRatio)
        }
    }

    static func set(_ au: AudioUnit, _ param: DynamicsParam, _ value: Float) {
        AudioUnitSetParameter(au, param.rawID, kAudioUnitScope_Global, 0, value, 0)
    }
}
