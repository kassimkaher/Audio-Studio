import Foundation
import AVFoundation

/// Builds concrete `AudioProcessingNode`s from a serialized spec and threads them
/// into an engine, with a dry/wet split so the chain can be globally crossfaded.
///
/// Both the live monitoring engine and the offline mixdown engine call this with
/// the *same* `EffectChainSpec`, guaranteeing identical processing in preview and
/// export. AV nodes can't be shared across engines, so fresh instances are made
/// each time — only the spec is shared.
enum ChainBuilder {

    /// Maps a stage spec to its concrete node implementation.
    /// `offline` keeps the convolution reverb at full IR length for export.
    static func makeNode(for spec: EffectStageSpec, offline: Bool = false) -> AudioProcessingNode {
        let node: AudioProcessingNode
        switch spec.kind {
        case .highPass:          node = HighPassNode(id: spec.id)
        case .noiseGate:         node = NoiseGateNode(id: spec.id)
        case .mlVoiceConversion: node = PassthroughNode(id: spec.id, isEnabled: spec.isEnabled)
        case .parametricEQ:      node = ParametricEQNode(id: spec.id)
        case .deEsser:           node = DeEsserNode(id: spec.id)
        case .compressor:        node = CompressorNode(id: spec.id)
        case .chorus:            node = PitchNode(id: spec.id, kind: .chorus)
        case .multiTapDelay:     node = DelayNode(id: spec.id, kind: .multiTapDelay)
        case .stereoDelay:       node = DelayNode(id: spec.id, kind: .stereoDelay)
        case .pitch:             node = PitchNode(id: spec.id, kind: .pitch)
        case .reverb:            node = ReverbNode(id: spec.id)
        case .distortion:        node = WarmthNode(id: spec.id)
        case .lowPass:           node = LowPassNode(id: spec.id)
        case .limiter:           node = LimiterNode(id: spec.id)
        case .convolutionReverb: node = ConvolutionReverbNode(id: spec.id, offline: offline)
        }
        node.isEnabled = spec.isEnabled
        return node
    }
}

/// A live instance of an effect chain attached to a specific engine.
final class ProcessingChain {
    /// Single entry node. The source connects here with ONE plain connection in
    /// its native format, so no converter is ever forced onto the source
    /// (critical for `inputNode`, which crashes with `isInputConnToConverter`
    /// if a converter is inserted on it). The fan-out happens from this mixer.
    private let splitMixer = AVAudioMixerNode()
    private let dryMixer = AVAudioMixerNode()
    private let wetMixer = AVAudioMixerNode()
    private let outputMixer = AVAudioMixerNode()
    private(set) var nodes: [AudioProcessingNode] = []
    private(set) var spec: EffectChainSpec
    /// When true (offline mixdown), the convolution reverb uses its full IR.
    private let offline: Bool

    init(spec: EffectChainSpec, offline: Bool = false) {
        self.spec = spec
        self.offline = offline
    }

    /// Attaches and connects the whole chain. `source` is the upstream node
    /// (e.g. mic input or a player). Returns the node downstream stages should
    /// connect from (the chain's output mixer).
    /// Convenience: source and processing share one format (playback/mixdown,
    /// where the source is a player already producing the render format).
    @discardableResult
    func install(into engine: AVAudioEngine, source: AVAudioNode, format: AVAudioFormat) -> AVAudioNode {
        install(into: engine, source: source, sourceFormat: format, processingFormat: format)
    }

    /// Installs the chain. The single edge off `source` uses `sourceFormat` (the
    /// source's native format) so no converter is ever forced onto the source
    /// node — critical for `inputNode`. The split mixer then upconverts to
    /// `processingFormat` (e.g. mono mic → stereo), and all downstream edges and
    /// the chain output run in `processingFormat`.
    @discardableResult
    func install(into engine: AVAudioEngine,
                 source: AVAudioNode,
                 sourceFormat: AVAudioFormat,
                 processingFormat: AVAudioFormat) -> AVAudioNode {
        engine.attach(splitMixer)
        engine.attach(dryMixer)
        engine.attach(wetMixer)
        engine.attach(outputMixer)

        // One plain connection from the source to the split mixer in the source's
        // own format — the mixer absorbs any conversion downstream.
        engine.connect(source, to: splitMixer, format: sourceFormat)

        // Build and attach (with internal wiring) the wet-path nodes in order.
        nodes = spec.stages.map { ChainBuilder.makeNode(for: $0, offline: offline) }
        nodes.forEach { $0.attach(to: engine, format: processingFormat) }

        // Fan the split mixer out (in processing format) to dry + wet-path head.
        let wetHead: AVAudioNode = nodes.first?.inputNode ?? wetMixer
        engine.connect(splitMixer, to: [
            AVAudioConnectionPoint(node: dryMixer, bus: 0),
            AVAudioConnectionPoint(node: wetHead, bus: 0)
        ], fromBus: 0, format: processingFormat)

        // Thread the wet path between successive nodes, one edge each.
        for i in nodes.indices.dropLast() {
            engine.connect(nodes[i].outputNode, to: nodes[i + 1].inputNode, format: processingFormat)
        }
        if let last = nodes.last {
            engine.connect(last.outputNode, to: wetMixer, format: processingFormat)
        }

        engine.connect(dryMixer, to: outputMixer, format: processingFormat)
        engine.connect(wetMixer, to: outputMixer, format: processingFormat)

        applyParameters()
        return outputMixer
    }

    /// Re-applies all stage parameters and the global wet/dry crossfade.
    func applyParameters() {
        for (node, stage) in zip(nodes, spec.stages) {
            node.isEnabled = stage.isEnabled
            node.applyParameters(stage, intensity: spec.intensity)
        }
        applyWetDry()
    }

    /// Updates the chain spec (e.g. after a slider move) and re-applies live.
    func update(spec newSpec: EffectChainSpec) {
        // Only parameter/wet-dry changes are live-applied; structural changes
        // (added/removed stages) require a rebuild handled by the caller.
        spec = newSpec
        applyParameters()
    }

    func setWetDry(_ value: Float) {
        spec.wetDryMix = max(0, min(value, 1))
        applyWetDry()
    }

    func setIntensity(_ value: Float) {
        spec.intensity = max(0, min(value, 1.5))
        applyParameters()
    }

    private func applyWetDry() {
        let wet = max(0, min(spec.wetDryMix, 1))
        wetMixer.outputVolume = wet
        dryMixer.outputVolume = 1 - wet
    }
}
