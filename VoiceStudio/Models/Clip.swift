import Foundation
import AVFoundation

/// A non-destructive view onto a region of an `AudioSource`, positioned on a track.
///
/// Trimming adjusts `sourceInFrame` / `sourceOutFrame`; moving adjusts
/// `timelineStartFrame`. The underlying file is never rewritten.
struct Clip: Identifiable, Codable, Hashable {
    let id: UUID
    let sourceID: UUID

    /// First sample (inclusive) of the source that this clip plays.
    var sourceInFrame: AVAudioFramePosition
    /// One-past-the-last sample (exclusive) of the source that this clip plays.
    var sourceOutFrame: AVAudioFramePosition
    /// Position of the clip's start on the track timeline, in frames.
    var timelineStartFrame: AVAudioFramePosition

    /// Linear per-clip gain (1.0 = unity).
    var gain: Float
    var fadeIn: TimeInterval
    var fadeOut: TimeInterval

    /// Per-clip effect chain (Audition-style). `nil` means the clip plays dry
    /// (no clip-level effects); the track's master chain still applies.
    /// Optional so projects saved before per-clip effects decode cleanly.
    var effectChain: EffectChainSpec?

    /// Display name shown on the clip and in the inspector.
    var name: String

    init(id: UUID = UUID(),
         sourceID: UUID,
         sourceInFrame: AVAudioFramePosition,
         sourceOutFrame: AVAudioFramePosition,
         timelineStartFrame: AVAudioFramePosition,
         gain: Float = 1.0,
         fadeIn: TimeInterval = 0,
         fadeOut: TimeInterval = 0,
         effectChain: EffectChainSpec? = nil,
         name: String = "Clip") {
        self.id = id
        self.sourceID = sourceID
        self.sourceInFrame = sourceInFrame
        self.sourceOutFrame = sourceOutFrame
        self.timelineStartFrame = timelineStartFrame
        self.gain = gain
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.effectChain = effectChain
        self.name = name
    }

    // Tolerant decoding so projects saved before `name`/`effectChain` existed
    // still load (missing keys fall back to defaults).
    enum CodingKeys: String, CodingKey {
        case id, sourceID, sourceInFrame, sourceOutFrame, timelineStartFrame
        case gain, fadeIn, fadeOut, effectChain, name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceID = try c.decode(UUID.self, forKey: .sourceID)
        sourceInFrame = try c.decode(AVAudioFramePosition.self, forKey: .sourceInFrame)
        sourceOutFrame = try c.decode(AVAudioFramePosition.self, forKey: .sourceOutFrame)
        timelineStartFrame = try c.decode(AVAudioFramePosition.self, forKey: .timelineStartFrame)
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 1.0
        fadeIn = try c.decodeIfPresent(TimeInterval.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(TimeInterval.self, forKey: .fadeOut) ?? 0
        effectChain = try c.decodeIfPresent(EffectChainSpec.self, forKey: .effectChain)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Clip"
    }

    /// An independent copy with a fresh id (for duplicate/copy actions),
    /// optionally repositioned on the timeline.
    func duplicated(timelineStartFrame newStart: AVAudioFramePosition? = nil) -> Clip {
        Clip(sourceID: sourceID, sourceInFrame: sourceInFrame, sourceOutFrame: sourceOutFrame,
             timelineStartFrame: newStart ?? timelineStartFrame,
             gain: gain, fadeIn: fadeIn, fadeOut: fadeOut, effectChain: effectChain, name: name)
    }

    /// Number of source frames this clip plays.
    var frameLength: AVAudioFramePosition { max(0, sourceOutFrame - sourceInFrame) }

    /// One-past-the-last timeline frame occupied by this clip.
    var timelineEndFrame: AVAudioFramePosition { timelineStartFrame + frameLength }

    func duration(sampleRate: Double) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameLength) / sampleRate
    }

    /// Splits the clip at an absolute timeline frame, returning two clips that
    /// together cover the same audio. Returns `nil` if the split point is not
    /// strictly inside the clip (so no zero-length pieces are ever created).
    func split(atTimelineFrame frame: AVAudioFramePosition) -> (Clip, Clip)? {
        guard frame > timelineStartFrame, frame < timelineEndFrame else { return nil }
        let offset = frame - timelineStartFrame   // frames into the clip

        var left = self
        left.sourceOutFrame = sourceInFrame + offset
        left.fadeOut = 0

        let right = Clip(
            sourceID: sourceID,
            sourceInFrame: sourceInFrame + offset,
            sourceOutFrame: sourceOutFrame,
            timelineStartFrame: frame,
            gain: gain,
            fadeIn: 0,
            fadeOut: fadeOut,
            effectChain: effectChain,
            name: name
        )
        return (left, right)
    }
}
