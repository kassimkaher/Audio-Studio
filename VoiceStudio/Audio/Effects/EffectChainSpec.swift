import Foundation
import AVFoundation

/// Global audio format used throughout the processing pipeline.
enum AudioFormatConstants {
    static let sampleRate: Double = 48_000
    static let channelCount: AVAudioChannelCount = 1   // mono capture; mixdown is stereo
    static let mixdownChannelCount: AVAudioChannelCount = 2
    static let bitDepth: Int = 24
}

/// The set of DSP stages the engine knows how to build. The order of an
/// `EffectChainSpec.stages` array is the order of processing.
enum EffectKind: String, Codable, CaseIterable {
    case highPass          // low-cut rumble filter
    case noiseGate         // dynamics processor as downward expander/gate
    case mlVoiceConversion // Phase-2 slot — pass-through in Phase 1
    case parametricEQ      // presence / warmth / air
    case deEsser           // narrow dynamic high-band tamer
    case compressor        // smooth vocal dynamics
    case chorus            // doubling / ensemble width
    case multiTapDelay     // echo bank
    case stereoDelay       // subtle stereo slap
    case pitch             // pitch / formant shift
    case reverb            // room / hall / mosque space
    case distortion        // subtle analog warmth
    case lowPass           // high-cut: tame harsh highs
    case limiter           // loudness / peak control
    case convolutionReverb // IR convolution — real acoustic-space fingerprint

    var displayName: String {
        switch self {
        case .highPass: return "Low Cut"
        case .noiseGate: return "Noise Gate"
        case .mlVoiceConversion: return "Voice Conversion (Beta)"
        case .parametricEQ: return "EQ"
        case .deEsser: return "De-esser"
        case .compressor: return "Compressor"
        case .chorus: return "Chorus / Double"
        case .multiTapDelay: return "Echo"
        case .stereoDelay: return "Stereo Delay"
        case .pitch: return "Pitch / Formant"
        case .reverb: return "Reverb"
        case .distortion: return "Warmth"
        case .lowPass: return "High Cut"
        case .limiter: return "Limiter"
        case .convolutionReverb: return "Convolution Space"
        }
    }

    var symbol: String {
        switch self {
        case .highPass: return "waveform.path.ecg"
        case .noiseGate: return "speaker.slash"
        case .mlVoiceConversion: return "brain"
        case .parametricEQ: return "slider.vertical.3"
        case .deEsser: return "mouth"
        case .compressor: return "arrow.down.right.and.arrow.up.left"
        case .chorus: return "person.3"
        case .multiTapDelay: return "repeat"
        case .stereoDelay: return "earbuds"
        case .pitch: return "tuningfork"
        case .reverb: return "building.columns"
        case .distortion: return "flame"
        case .lowPass: return "waveform.path"
        case .limiter: return "gauge.with.dots.needle.bottom.50percent"
        case .convolutionReverb: return "building.columns.fill"
        }
    }

    /// Filters the user can add/edit (the ML slot is reserved & not user-addable).
    static var userAddable: [EffectKind] {
        [.highPass, .lowPass, .parametricEQ, .deEsser, .noiseGate, .compressor,
         .limiter, .chorus, .pitch, .stereoDelay, .multiTapDelay, .reverb,
         .convolutionReverb, .distortion]
    }
}

/// How a parameter value is displayed/edited.
enum ParamFormat { case percent, hz, decibels, seconds, milliseconds, ratio, cents, count

    func string(_ v: Float) -> String {
        switch self {
        case .percent: return String(format: "%.0f%%", v * 100)
        case .hz: return v >= 1000 ? String(format: "%.1f kHz", v / 1000) : String(format: "%.0f Hz", v)
        case .decibels: return String(format: "%.1f dB", v)
        case .seconds: return String(format: "%.2f s", v)
        case .milliseconds: return String(format: "%.0f ms", v)
        case .ratio: return String(format: "%.1f:1", v)
        case .cents: return String(format: "%.0f¢", v)
        case .count: return String(format: "%.0f", v)
        }
    }
}

/// An editable parameter of an effect stage (drives the UI sliders).
struct EffectParam: Identifiable, Hashable {
    let key: String
    let label: String
    let range: ClosedRange<Float>
    let defaultValue: Float
    let format: ParamFormat
    var id: String { key }
}

extension EffectKind {
    /// The editable parameters exposed in the effect rack for this kind.
    var editableParams: [EffectParam] {
        switch self {
        case .highPass:
            return [EffectParam(key: ParamKeys.frequency, label: "Frequency", range: 20...500, defaultValue: 90, format: .hz)]
        case .lowPass:
            return [EffectParam(key: ParamKeys.frequency, label: "Frequency", range: 2000...20000, defaultValue: 16000, format: .hz)]
        case .noiseGate:
            return [EffectParam(key: ParamKeys.threshold, label: "Threshold", range: -80...0, defaultValue: -45, format: .decibels),
                    EffectParam(key: ParamKeys.release, label: "Release", range: 0.02...1, defaultValue: 0.12, format: .seconds)]
        case .parametricEQ:
            return [EffectParam(key: ParamKeys.warmthGain, label: "Warmth (250 Hz)", range: -12...12, defaultValue: 0, format: .decibels),
                    EffectParam(key: ParamKeys.presenceGain, label: "Presence (4 kHz)", range: -12...12, defaultValue: 2, format: .decibels),
                    EffectParam(key: ParamKeys.airGain, label: "Air (12 kHz)", range: -12...12, defaultValue: 2, format: .decibels)]
        case .deEsser:
            return [EffectParam(key: ParamKeys.deEssFrequency, label: "Frequency", range: 3000...10000, defaultValue: 6500, format: .hz),
                    EffectParam(key: ParamKeys.deEssAmount, label: "Amount", range: -15...0, defaultValue: -4, format: .decibels)]
        case .compressor:
            return [EffectParam(key: ParamKeys.threshold, label: "Threshold", range: -40...0, defaultValue: -18, format: .decibels),
                    EffectParam(key: ParamKeys.ratio, label: "Ratio", range: 1...20, defaultValue: 3, format: .ratio),
                    EffectParam(key: ParamKeys.attack, label: "Attack", range: 0.001...0.1, defaultValue: 0.005, format: .seconds),
                    EffectParam(key: ParamKeys.release, label: "Release", range: 0.02...1, defaultValue: 0.18, format: .seconds),
                    EffectParam(key: ParamKeys.masterGain, label: "Make-up Gain", range: -6...18, defaultValue: 3, format: .decibels)]
        case .limiter:
            return [EffectParam(key: ParamKeys.preGain, label: "Loudness", range: 0...20, defaultValue: 6, format: .decibels)]
        case .chorus:
            return [EffectParam(key: ParamKeys.detuneCents, label: "Detune", range: 0...30, defaultValue: 8, format: .cents),
                    EffectParam(key: ParamKeys.mix, label: "Mix", range: 0...1, defaultValue: 0.2, format: .percent)]
        case .pitch:
            return [EffectParam(key: ParamKeys.detuneCents, label: "Pitch", range: -1200...1200, defaultValue: 0, format: .cents)]
        case .stereoDelay:
            return [EffectParam(key: ParamKeys.time, label: "Time", range: 0.05...1, defaultValue: 0.22, format: .seconds),
                    EffectParam(key: ParamKeys.feedback, label: "Feedback", range: 0...0.9, defaultValue: 0.18, format: .percent),
                    EffectParam(key: ParamKeys.mix, label: "Mix", range: 0...1, defaultValue: 0.18, format: .percent)]
        case .multiTapDelay:
            return [EffectParam(key: ParamKeys.time, label: "Time", range: 0.05...1, defaultValue: 0.32, format: .seconds),
                    EffectParam(key: ParamKeys.taps, label: "Taps", range: 1...5, defaultValue: 3, format: .count),
                    EffectParam(key: ParamKeys.feedback, label: "Feedback", range: 0...0.9, defaultValue: 0.25, format: .percent),
                    EffectParam(key: ParamKeys.mix, label: "Mix", range: 0...1, defaultValue: 0.22, format: .percent)]
        case .reverb:
            return [EffectParam(key: ParamKeys.mix, label: "Mix", range: 0...1, defaultValue: 0.4, format: .percent),
                    EffectParam(key: ParamKeys.preDelay, label: "Pre-delay", range: 0...120, defaultValue: 20, format: .milliseconds)]
        case .distortion:
            return [EffectParam(key: ParamKeys.mix, label: "Amount", range: 0...0.5, defaultValue: 0.08, format: .percent)]
        case .convolutionReverb:
            return [EffectParam(key: ParamKeys.mix, label: "Wet / Dry", range: 0...1, defaultValue: 0.45, format: .percent)]
        case .mlVoiceConversion:
            return []
        }
    }

    /// A default params dictionary for a freshly added stage.
    var defaultParams: [String: Float] {
        var d: [String: Float] = [:]
        for p in editableParams { d[p.key] = p.defaultValue }
        if self == .reverb { d[ParamKeys.reverbPreset] = Float(2 /* cathedral-ish */) }
        return d
    }
}

/// One configurable stage. Parameters are stored as a named float map so the
/// spec stays trivially `Codable` and forward-compatible; each concrete node
/// documents the keys it reads in `ParamKeys`.
struct EffectStageSpec: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: EffectKind
    var isEnabled: Bool
    var params: [String: Float]
    /// String-valued parameters (e.g. the convolution IR id). Optional so specs
    /// saved before it existed decode cleanly.
    var stringParams: [String: String]?

    init(id: UUID = UUID(), kind: EffectKind, isEnabled: Bool = true,
         params: [String: Float] = [:], stringParams: [String: String]? = nil) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.params = params
        self.stringParams = stringParams
    }

    func param(_ key: String, default def: Float) -> Float { params[key] ?? def }
}

/// An ordered, serializable description of a processing chain plus global controls.
struct EffectChainSpec: Codable, Hashable {
    var stages: [EffectStageSpec]
    /// 0 = fully dry (bypass effects), 1 = fully wet (all effects). Crossfaded at runtime.
    var wetDryMix: Float
    /// Master scale applied to "depth" parameters (reverb mix, delay feedback, etc.).
    var intensity: Float

    init(stages: [EffectStageSpec] = [], wetDryMix: Float = 1.0, intensity: Float = 1.0) {
        self.stages = stages
        self.wetDryMix = wetDryMix
        self.intensity = intensity
    }

    static let empty = EffectChainSpec(stages: [], wetDryMix: 0, intensity: 1)

    /// The standard slot ordering, with the ML slot reserved as a pass-through so
    /// Phase 2 can swap it in without reordering anything.
    static func standardChain(_ stages: [EffectStageSpec]) -> EffectChainSpec {
        EffectChainSpec(stages: stages)
    }
}

/// Canonical parameter key names, kept in one place so spec authors and node
/// builders cannot drift apart.
enum ParamKeys {
    // highPass
    static let frequency = "frequency"
    // noiseGate / compressor (AVAudioUnitDynamicsProcessor)
    static let threshold = "threshold"   // dB
    static let ratio = "ratio"
    static let attack = "attack"         // seconds
    static let release = "release"       // seconds
    static let masterGain = "masterGain" // dB
    // parametric EQ
    static let warmthGain = "warmthGain" // dB at ~250 Hz
    static let presenceGain = "presenceGain" // dB at ~4 kHz
    static let airGain = "airGain"       // dB high shelf ~12 kHz
    // de-esser
    static let deEssFrequency = "deEssFrequency"
    static let deEssAmount = "deEssAmount" // dB cut
    // chorus / pitch
    static let detuneCents = "detuneCents"
    static let depthMs = "depthMs"
    static let mix = "mix"               // 0...1 wet
    // multi-tap / stereo delay
    static let time = "time"             // seconds (base tap)
    static let taps = "taps"             // number of taps
    static let feedback = "feedback"     // 0...1
    // reverb
    static let preDelay = "preDelay"     // ms, modeled via series delay
    static let reverbPreset = "reverbPreset" // raw value of AVAudioUnitReverbPreset
    // distortion
    static let drive = "drive"
    // limiter
    static let preGain = "preGain"       // dB loudness into the limiter
    // convolution reverb (string param)
    static let ir = "ir"                 // impulse-response identifier
}
