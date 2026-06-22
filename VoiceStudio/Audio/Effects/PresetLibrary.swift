import Foundation
import AVFoundation

/// A named, ready-to-use effect chain shown in the preset picker.
struct VocalPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let category: PresetCategory
    let subtitle: String
    let symbol: String   // SF Symbol
    let chain: EffectChainSpec
}

enum PresetCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case singers = "Singers"
    case anasheed = "Anasheed"
    case quran = "Qur'an"
    case signature = "Pro"

    var id: String { rawValue }
}

/// The tuned configurations for every vocal category. Values are deliberately
/// conservative defaults; the UI scales "depth" parameters by chain `intensity`.
enum PresetLibrary {

    // MARK: Reusable cleanup stages

    static func highPass(_ hz: Float = 90) -> EffectStageSpec {
        EffectStageSpec(kind: .highPass, params: [ParamKeys.frequency: hz])
    }

    static func noiseGate(threshold: Float = -45) -> EffectStageSpec {
        EffectStageSpec(kind: .noiseGate, params: [
            ParamKeys.threshold: threshold,
            ParamKeys.ratio: 10,
            ParamKeys.attack: 0.002,
            ParamKeys.release: 0.12
        ])
    }

    /// Reserved Phase-2 voice-conversion slot. Disabled pass-through in Phase 1.
    static var mlSlot: EffectStageSpec {
        EffectStageSpec(kind: .mlVoiceConversion, isEnabled: false)
    }

    // MARK: Presets

    static let general = VocalPreset(
        id: "general.clean",
        name: "Clean Vocal",
        category: .general,
        subtitle: "Presence, warmth & air with gentle cleanup",
        symbol: "mic",
        chain: EffectChainSpec(stages: [
            highPass(85),
            noiseGate(threshold: -48),
            mlSlot,
            EffectStageSpec(kind: .parametricEQ, params: [
                ParamKeys.warmthGain: -1.5,    // clear mud ~250 Hz
                ParamKeys.presenceGain: 2.0,   // presence ~4 kHz
                ParamKeys.airGain: 2.5         // air shelf ~12 kHz
            ]),
            EffectStageSpec(kind: .deEsser, params: [
                ParamKeys.deEssFrequency: 6500,
                ParamKeys.deEssAmount: -4
            ])
        ], wetDryMix: 1.0, intensity: 0.8)
    )

    static let singers = VocalPreset(
        id: "singers.studio",
        name: "Studio Singer",
        category: .singers,
        subtitle: "Smooth compression, plate reverb & stereo delay",
        symbol: "music.mic",
        chain: EffectChainSpec(stages: [
            highPass(90),
            noiseGate(threshold: -50),
            mlSlot,
            EffectStageSpec(kind: .parametricEQ, params: [
                ParamKeys.warmthGain: 1.0,
                ParamKeys.presenceGain: 2.5,
                ParamKeys.airGain: 3.0
            ]),
            EffectStageSpec(kind: .deEsser, params: [
                ParamKeys.deEssFrequency: 7000,
                ParamKeys.deEssAmount: -5
            ]),
            EffectStageSpec(kind: .compressor, params: [
                ParamKeys.threshold: -18,
                ParamKeys.ratio: 3,
                ParamKeys.attack: 0.005,
                ParamKeys.release: 0.18,
                ParamKeys.masterGain: 3
            ]),
            EffectStageSpec(kind: .stereoDelay, params: [
                ParamKeys.time: 0.22,
                ParamKeys.feedback: 0.18,
                ParamKeys.mix: 0.18
            ]),
            EffectStageSpec(kind: .reverb, params: [
                ParamKeys.reverbPreset: Float(AVAudioUnitReverbPreset.plate.rawValue),
                ParamKeys.mix: 0.28
            ])
        ], wetDryMix: 1.0, intensity: 0.85)
    )

    static let anasheed = VocalPreset(
        id: "anasheed.majestic",
        name: "Majestic Anasheed",
        category: .anasheed,
        subtitle: "Lush hall reverb with subtle ensemble doubling",
        symbol: "moon.stars",
        chain: EffectChainSpec(stages: [
            highPass(95),
            noiseGate(threshold: -50),
            mlSlot,
            EffectStageSpec(kind: .parametricEQ, params: [
                ParamKeys.warmthGain: 1.5,
                ParamKeys.presenceGain: 1.5,
                ParamKeys.airGain: 2.0
            ]),
            EffectStageSpec(kind: .deEsser, params: [
                ParamKeys.deEssFrequency: 6800,
                ParamKeys.deEssAmount: -4
            ]),
            EffectStageSpec(kind: .compressor, params: [
                ParamKeys.threshold: -16,
                ParamKeys.ratio: 2.5,
                ParamKeys.attack: 0.008,
                ParamKeys.release: 0.2,
                ParamKeys.masterGain: 2
            ]),
            EffectStageSpec(kind: .chorus, params: [
                ParamKeys.detuneCents: 8,
                ParamKeys.depthMs: 18,
                ParamKeys.mix: 0.22
            ]),
            EffectStageSpec(kind: .reverb, params: [
                ParamKeys.reverbPreset: Float(AVAudioUnitReverbPreset.largeHall2.rawValue),
                ParamKeys.mix: 0.4
            ])
        ], wetDryMix: 1.0, intensity: 0.9)
    )

    static let quran = VocalPreset(
        id: "quran.haram",
        name: "Grand Mosque",
        category: .quran,
        subtitle: "Haram-style space, multi-tap echo & legible mids",
        symbol: "building.columns",
        chain: EffectChainSpec(stages: [
            highPass(100),
            noiseGate(threshold: -52),
            mlSlot,
            // Tonal presence EQ + formant stabilization: keep mids legible
            // through the heavy space so articulation is preserved.
            EffectStageSpec(kind: .parametricEQ, params: [
                ParamKeys.warmthGain: -1.0,
                ParamKeys.presenceGain: 3.0,   // mid-range clarity
                ParamKeys.airGain: 1.0
            ]),
            EffectStageSpec(kind: .deEsser, params: [
                ParamKeys.deEssFrequency: 6500,
                ParamKeys.deEssAmount: -3
            ]),
            EffectStageSpec(kind: .compressor, params: [
                ParamKeys.threshold: -14,
                ParamKeys.ratio: 2,
                ParamKeys.attack: 0.01,
                ParamKeys.release: 0.25,
                ParamKeys.masterGain: 2
            ]),
            // Multi-tap echo emulating acoustic bounce of large historical spaces.
            EffectStageSpec(kind: .multiTapDelay, params: [
                ParamKeys.time: 0.32,
                ParamKeys.taps: 3,
                ParamKeys.feedback: 0.25,
                ParamKeys.mix: 0.22
            ]),
            // Grand-mosque reverb: long decay + pre-delay modeled by a series delay.
            EffectStageSpec(kind: .reverb, params: [
                ParamKeys.reverbPreset: Float(AVAudioUnitReverbPreset.cathedral.rawValue),
                ParamKeys.preDelay: 60,
                ParamKeys.mix: 0.55
            ])
        ], wetDryMix: 1.0, intensity: 1.0)
    )

    /// "Hussaini/Nasheed Professional" — a multi-stage studio chain: clarity
    /// compression → IR convolution spatial presence (short, dense, articulate) →
    /// tonal balance. The convolution space is a real impulse response.
    static let hussainiPro = VocalPreset(
        id: "signature.hussaini",
        name: "Hussaini / Nasheed Pro",
        category: .signature,
        subtitle: "Studio clarity + real convolution space (Hussaini Hall)",
        symbol: "sparkles",
        chain: EffectChainSpec(stages: [
            highPass(85),
            noiseGate(threshold: -50),
            mlSlot,
            // Stage 1 — Master Clarity (compressor + tonal EQ; approximates a
            // mastering multiband by leaning the EQ around the compression).
            EffectStageSpec(kind: .compressor, params: [
                ParamKeys.threshold: -16, ParamKeys.ratio: 2.5,
                ParamKeys.attack: 0.006, ParamKeys.release: 0.16, ParamKeys.masterGain: 3
            ]),
            EffectStageSpec(kind: .parametricEQ, params: [
                ParamKeys.warmthGain: 1.5, ParamKeys.presenceGain: 2.5, ParamKeys.airGain: 2.5
            ]),
            // Stage 3 — tonal balance (de-ess to keep articulation crisp).
            EffectStageSpec(kind: .deEsser, params: [
                ParamKeys.deEssFrequency: 6800, ParamKeys.deEssAmount: -5
            ]),
            // Stage 2 — Spatial Presence: real IR convolution, modest wet so the
            // recitation stays legible through the thick, majestic space.
            EffectStageSpec(kind: .convolutionReverb,
                            params: [ParamKeys.mix: 0.4],
                            stringParams: [ParamKeys.ir: "HussainiHall"]),
            // Gentle loudness polish.
            EffectStageSpec(kind: .limiter, params: [ParamKeys.preGain: 5])
        ], wetDryMix: 1.0, intensity: 0.95)
    )

    /// "Live Majlis / Crowded Hall" — the voice placed in a packed audience via
    /// the crowd-absorptive `LiveMajlis` IR: dark highs, warm low-mids, and wide
    /// early reflections. Pair with Audience Mode for the full atmosphere.
    static let liveMajlis = VocalPreset(
        id: "signature.liveMajlis",
        name: "Live Majlis / Crowded Hall",
        category: .signature,
        subtitle: "Packed-audience space: warm low-mids, softened highs, wide reflections",
        symbol: "person.3.fill",
        chain: EffectChainSpec(stages: [
            highPass(90),
            noiseGate(threshold: -50),
            mlSlot,
            // Crowd tonality: lift low-mid warmth, ease presence, roll off air
            // (a packed hall absorbs the highs).
            EffectStageSpec(kind: .parametricEQ, params: [
                ParamKeys.warmthGain: 2.5, ParamKeys.presenceGain: 1.0, ParamKeys.airGain: -3.0
            ]),
            EffectStageSpec(kind: .deEsser, params: [
                ParamKeys.deEssFrequency: 6500, ParamKeys.deEssAmount: -4
            ]),
            EffectStageSpec(kind: .compressor, params: [
                ParamKeys.threshold: -16, ParamKeys.ratio: 2.5,
                ParamKeys.attack: 0.008, ParamKeys.release: 0.2, ParamKeys.masterGain: 2
            ]),
            // Spatial presence: the crowd-absorptive impulse response.
            EffectStageSpec(kind: .convolutionReverb,
                            params: [ParamKeys.mix: 0.5],
                            stringParams: [ParamKeys.ir: "LiveMajlis"])
        ], wetDryMix: 1.0, intensity: 0.95)
    )

    static let all: [VocalPreset] = [general, singers, anasheed, quran, hussainiPro, liveMajlis]

    static func presets(in category: PresetCategory) -> [VocalPreset] {
        all.filter { $0.category == category }
    }

    static func preset(id: String) -> VocalPreset? { all.first { $0.id == id } }
}
