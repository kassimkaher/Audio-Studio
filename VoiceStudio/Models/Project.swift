import Foundation
import AVFoundation

/// The complete, serializable editing document — the single source of truth that
/// drives live monitoring, playback and offline mixdown alike.
struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var sampleRate: Double
    var tracks: [Track]
    /// Every source referenced by any clip, keyed for quick lookup at render time.
    var sources: [AudioSource]
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String = "Untitled",
         sampleRate: Double = AudioFormatConstants.sampleRate,
         tracks: [Track] = [],
         sources: [AudioSource] = [],
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sampleRate = sampleRate
        self.tracks = tracks
        self.sources = sources
        self.updatedAt = updatedAt
    }

    func source(for id: UUID) -> AudioSource? { sources.first { $0.id == id } }

    /// True if any track is soloed; used to compute effective mute state.
    var hasSolo: Bool { tracks.contains { $0.isSoloed } }

    /// Whether a track should actually be heard given mute/solo state across the project.
    func isAudible(_ track: Track) -> Bool {
        if track.isMuted { return false }
        if hasSolo { return track.isSoloed }
        return true
    }

    /// Total length of the montage in frames (longest track).
    var totalFrames: AVAudioFramePosition { tracks.map(\.endFrame).max() ?? 0 }

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(totalFrames) / sampleRate
    }

    var clipCount: Int { tracks.reduce(0) { $0 + $1.clips.count } }

    // MARK: Track & clip operations

    /// Appends a new empty track and returns its id.
    @discardableResult
    mutating func addTrack(kind: TrackKind = .vocal, name: String? = nil) -> UUID {
        // Bilingual default names per the Sacred Audio DAW identity.
        let fallback = kind == .background ? "Raddah · ردّة \(tracks.count + 1)" : "Lane \(tracks.count + 1)"
        let track = Track(name: name ?? fallback, kind: kind)
        tracks.append(track)
        return track.id
    }

    mutating func removeTrack(_ id: UUID) {
        tracks.removeAll { $0.id == id }
    }

    mutating func renameTrack(_ id: UUID, to name: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].name = name
    }

    /// Duplicates a track (with its clips & effects) directly below it.
    @discardableResult
    mutating func duplicateTrack(_ id: UUID) -> UUID? {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = tracks[i].duplicated()
        tracks.insert(copy, at: i + 1)
        return copy.id
    }

    /// Duplicates a clip onto the same track, placed right after the original.
    @discardableResult
    mutating func duplicateClip(_ clipID: UUID) -> UUID? {
        guard let ti = tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let ci = tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return nil }
        let copy = tracks[ti].clips[ci].duplicated(timelineStartFrame: tracks[ti].clips[ci].timelineEndFrame)
        tracks[ti].clips.append(copy)
        return copy.id
    }

    /// Moves a clip to another track and/or timeline position. Used by drag/drop.
    mutating func moveClip(_ clipID: UUID, toTrack targetTrackID: UUID, atFrame frame: AVAudioFramePosition) {
        guard let srcIdx = tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let clipIdx = tracks[srcIdx].clips.firstIndex(where: { $0.id == clipID }),
              let dstIdx = tracks.firstIndex(where: { $0.id == targetTrackID }) else { return }
        var clip = tracks[srcIdx].clips.remove(at: clipIdx)
        clip.timelineStartFrame = max(0, frame)
        tracks[dstIdx].clips.append(clip)
    }

    /// A fresh project with a single empty track to start from.
    static func makeDefault(name: String = "New Project") -> Project {
        Project(name: name, tracks: [Track(name: "Lead Lane", kind: .vocal)])
    }
}
