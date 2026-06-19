import Foundation
import AVFoundation

/// A pluggable unit of the processing chain. Each conformer wraps one or more
/// `AVAudioNode`s (or, for Phase-2 ML/custom DSP, a render block) and exposes an
/// explicit input/output node so `ChainBuilder` can thread them together with
/// exactly one connection per edge — regardless of internal topology.
///
/// This protocol is the seam that lets a future `MLVoiceConversionNode` slot
/// into the chain without rearchitecting anything: the chain is just an ordered
/// array of these, and the ML node is one more conformer.
protocol AudioProcessingNode: AnyObject {
    var id: UUID { get }
    var kind: EffectKind { get }
    var displayName: String { get }

    /// Bypass without removing from the graph. Implementations should make this
    /// a true signal bypass (e.g. reverb wetDryMix→0) so it is glitch-free.
    var isEnabled: Bool { get set }

    /// Underlying AV nodes that must be attached to the engine.
    var avNodes: [AVAudioNode] { get }

    /// The node that receives the upstream signal.
    var inputNode: AVAudioNode { get }
    /// The node whose output feeds the next stage.
    var outputNode: AVAudioNode { get }

    /// Optional render block for custom/ML stages backed by `AVAudioSourceNode`.
    /// `nil` for ordinary AVAudioUnit-based stages.
    var renderBlock: AVAudioSourceNodeRenderBlock? { get }

    /// Attach this node's AV nodes to the engine and wire any *internal*
    /// connections (e.g. a reverb's series pre-delay). The builder connects the
    /// external input/output edges.
    func attach(to engine: AVAudioEngine, format: AVAudioFormat)

    /// Apply (or re-apply) parameters from the spec, scaled by chain `intensity`.
    func applyParameters(_ spec: EffectStageSpec, intensity: Float)
}

extension AudioProcessingNode {
    var renderBlock: AVAudioSourceNodeRenderBlock? { nil }

    /// Most nodes are a single AV node: input == output == that node.
    var inputNode: AVAudioNode { avNodes.first! }
    var outputNode: AVAudioNode { avNodes.last! }
}
