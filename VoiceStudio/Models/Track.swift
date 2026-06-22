import Foundation
import AVFoundation

enum TrackKind: String, Codable, CaseIterable {
    case vocal
    case background

    var displayName: String {
        switch self {
        case .vocal: return "Vocal"
        case .background: return "Background"
        }
    }
}

/// A single timeline lane holding ordered clips, with its own effect chain and mix state.
struct Track: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var kind: TrackKind
    var clips: [Clip]

    /// Linear track volume (0...~2).
    var volume: Float
    var isMuted: Bool
    var isSoloed: Bool

    /// The serialized effect chain applied to this track during playback and mixdown.
    var effectChain: EffectChainSpec

    /// Record-arm: the armed track is the capture target for the next take.
    /// **Transient** — excluded from `CodingKeys` so it never persists.
    var isArmed: Bool = false

    init(id: UUID = UUID(),
         name: String,
         kind: TrackKind,
         clips: [Clip] = [],
         volume: Float = 1.0,
         isMuted: Bool = false,
         isSoloed: Bool = false,
         effectChain: EffectChainSpec = .empty) {
        self.id = id
        self.name = name
        self.kind = kind
        self.clips = clips
        self.volume = volume
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.effectChain = effectChain
    }

    // `isArmed` intentionally omitted → transient, never encoded/decoded.
    enum CodingKeys: String, CodingKey {
        case id, name, kind, clips, volume, isMuted, isSoloed, effectChain
    }

    /// Last timeline frame occupied by any clip on this track.
    var endFrame: AVAudioFramePosition { clips.map(\.timelineEndFrame).max() ?? 0 }

    /// An independent copy with a fresh id and freshly-id'd clips (for duplicate).
    func duplicated(named newName: String? = nil) -> Track {
        Track(name: newName ?? "\(name) copy", kind: kind,
              clips: clips.map { $0.duplicated() },
              volume: volume, isMuted: isMuted, isSoloed: false, effectChain: effectChain)
    }
}
