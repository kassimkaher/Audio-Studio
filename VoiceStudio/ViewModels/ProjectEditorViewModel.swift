import Foundation
import AVFoundation
import Combine

/// Owns the open project and every editing operation. Mutations update the
/// Codable `project` (the single source of truth), autosave, and keep live
/// playback mix/chains in sync. Also provides timeline frame↔point math.
@MainActor
final class ProjectEditorViewModel: ObservableObject {
    @Published var project: Project { didSet { scheduleSave() } }
    @Published var selectedClipID: UUID?
    @Published var selectedTrackID: UUID?
    @Published var pixelsPerSecond: CGFloat = 60

    let env: AppEnvironment
    private var saveWork: DispatchWorkItem?

    /// Copy/paste clipboard (a clip or a whole track).
    private var clipboardClip: Clip?
    private var clipboardTrack: Track?
    var canPaste: Bool { clipboardClip != nil || clipboardTrack != nil }

    init(project: Project, env: AppEnvironment) {
        self.project = project
        self.env = env
    }

    var playback: PlaybackService { env.playbackService }
    var store: ProjectStore { env.projectStore }
    var sampleRate: Double { project.sampleRate }

    // MARK: Persistence (debounced autosave)

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = project
        let work = DispatchWorkItem { [store] in try? store.save(snapshot) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        try? store.save(project)
    }

    // MARK: Timeline geometry

    func x(forFrame frame: AVAudioFramePosition) -> CGFloat {
        CGFloat(Double(frame) / sampleRate) * pixelsPerSecond
    }
    func frame(forX x: CGFloat) -> AVAudioFramePosition {
        AVAudioFramePosition(max(0, Double(x / pixelsPerSecond) * sampleRate))
    }
    func frames(forWidth width: CGFloat) -> AVAudioFramePosition {
        AVAudioFramePosition(Double(width / pixelsPerSecond) * sampleRate)
    }

    // MARK: Selection

    func select(_ clip: Clip, in track: Track) {
        selectedClipID = clip.id
        selectedTrackID = track.id
    }
    func clearSelection() { selectedClipID = nil; selectedTrackID = nil }
    var hasSelection: Bool { selectedClipID != nil }

    func track(_ id: UUID) -> Track? { project.tracks.first { $0.id == id } }
    /// The id of the track currently holding the given clip.
    func trackID(ofClip clipID: UUID) -> UUID? {
        project.tracks.first { $0.clips.contains { $0.id == clipID } }?.id
    }
    func clip(_ id: UUID) -> (clip: Clip, source: AudioSource)? {
        for t in project.tracks {
            if let c = t.clips.first(where: { $0.id == id }), let s = project.source(for: c.sourceID) {
                return (c, s)
            }
        }
        return nil
    }

    private func trackIndex(_ id: UUID) -> Int? { project.tracks.firstIndex { $0.id == id } }

    // MARK: Tracks

    func addTrack() { project.addTrack() }

    @discardableResult
    func addTrackReturningID() -> UUID { project.addTrack() }

    func removeTrack(_ id: UUID) {
        // Free files owned solely by clips on this track.
        if let idx = trackIndex(id) {
            let sourceIDs = project.tracks[idx].clips.map(\.sourceID)
            project.removeTrack(id)
            sourceIDs.forEach { cleanupSourceIfUnused($0) }
        }
        if selectedTrackID == id { clearSelection() }
    }

    func renameProject(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        project.name = trimmed
    }

    func renameTrack(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        project.renameTrack(id, to: trimmed)
    }

    /// Duplicates a track (clips + effects) directly below it.
    func duplicateTrack(_ id: UUID) {
        if let newID = project.duplicateTrack(id) { selectedTrackID = newID; selectedClipID = nil }
    }

    /// Duplicates a clip onto the same track, after the original, and selects it.
    func duplicateClip(_ clipID: UUID) {
        if let newID = project.duplicateClip(clipID) { selectedClipID = newID }
    }

    /// Duplicates a clip onto a brand-new track at the SAME timeline position, so
    /// the copy plays in parallel with the original. Returns/selects the copy.
    func duplicateClipToNewTrack(_ clipID: UUID) {
        guard let found = clip(clipID) else { return }
        let newTrackID = project.addTrack(name: "Track \(project.tracks.count + 1)")
        guard let i = trackIndex(newTrackID) else { return }
        let copy = found.clip.duplicated(timelineStartFrame: found.clip.timelineStartFrame)
        project.tracks[i].clips.append(copy)
        selectedTrackID = newTrackID
        selectedClipID = copy.id
    }

    /// Shifts a clip along the timeline by `deltaFrames` (clamped at 0).
    func nudgeClip(_ clipID: UUID, byFrames deltaFrames: AVAudioFramePosition) {
        guard let i = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let ci = project.tracks[i].clips.firstIndex(where: { $0.id == clipID }) else { return }
        let newStart = max(0, project.tracks[i].clips[ci].timelineStartFrame + deltaFrames)
        project.tracks[i].clips[ci].timelineStartFrame = newStart
    }

    /// Moves a clip's start to an absolute timeline frame (e.g. the playhead).
    func setClipStart(_ clipID: UUID, toFrame frame: AVAudioFramePosition) {
        guard let i = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let ci = project.tracks[i].clips.firstIndex(where: { $0.id == clipID }) else { return }
        project.tracks[i].clips[ci].timelineStartFrame = max(0, frame)
    }

    // MARK: Copy / paste / duplicate (keyboard + menus)

    /// ⌘C — copy the selected clip, or (if none) the selected track.
    func copySelection() {
        if let cid = selectedClipID, let found = clip(cid) {
            clipboardClip = found.clip; clipboardTrack = nil
        } else if let tid = selectedTrackID, let t = track(tid) {
            clipboardTrack = t; clipboardClip = nil
        }
    }

    /// ⌘V — paste the clipboard: a clip onto the selected track at the playhead
    /// (no overlap), or a whole track appended to the project.
    func pasteClipboard() {
        if let c = clipboardClip {
            let targetID = selectedTrackID
                ?? selectedClipID.flatMap { trackID(ofClip: $0) }
                ?? project.tracks.first?.id
            guard let tid = targetID, let i = trackIndex(tid) else { return }
            let len = c.frameLength
            let playhead = max(0, playback.currentFrame)
            let overlaps = project.tracks[i].clips.contains {
                playhead < $0.timelineEndFrame && (playhead + len) > $0.timelineStartFrame
            }
            let pos = overlaps ? project.tracks[i].endFrame : playhead
            let copy = c.duplicated(timelineStartFrame: pos)
            project.tracks[i].clips.append(copy)
            selectedClipID = copy.id
        } else if let t = clipboardTrack {
            let copy = t.duplicated()
            project.tracks.append(copy)
            selectedTrackID = copy.id; selectedClipID = nil
        }
    }

    /// ⌘D — duplicate the current selection in place (clip or track).
    func duplicateSelection() {
        if let cid = selectedClipID { duplicateClip(cid) }
        else if let tid = selectedTrackID { duplicateTrack(tid) }
    }

    func setVolume(_ v: Float, forTrack id: UUID) {
        guard let i = trackIndex(id) else { return }
        project.tracks[i].volume = v
        playback.applyMix(from: project)
    }
    func toggleMute(_ id: UUID) {
        guard let i = trackIndex(id) else { return }
        project.tracks[i].isMuted.toggle()
        playback.applyMix(from: project)
    }
    func toggleSolo(_ id: UUID) {
        guard let i = trackIndex(id) else { return }
        project.tracks[i].isSoloed.toggle()
        playback.applyMix(from: project)
    }

    // MARK: Track master effects

    func setTrackPreset(_ preset: VocalPreset, forTrack id: UUID) {
        guard let i = trackIndex(id) else { return }
        project.tracks[i].effectChain = preset.chain
        playback.updateChain(for: id, spec: preset.chain)
    }
    func updateTrackChain(_ chain: EffectChainSpec, forTrack id: UUID) {
        guard let i = trackIndex(id) else { return }
        project.tracks[i].effectChain = chain
        playback.updateChain(for: id, spec: chain)
    }

    // MARK: Clips

    /// Commits a recorded/imported take as a new clip on the given track.
    /// `alignFrames` time-aligns an overdub take: **positive** trims leading frames
    /// (shifts the take *earlier*, removing capture delay); **negative** delays it
    /// *later* on the timeline (if over-compensated).
    func appendClip(source: AudioSource, chain: EffectChainSpec?, toTrack trackID: UUID?,
                    name: String, alignFrames: AVAudioFramePosition = 0) {
        if !project.sources.contains(where: { $0.id == source.id }) {
            project.sources.append(source)
        }
        let targetID = trackID ?? project.tracks.first?.id ?? project.addTrack()
        guard let i = trackIndex(targetID) else { return }

        let sourceIn = alignFrames > 0 ? min(alignFrames, max(0, source.frameCount - 1)) : 0
        let delay = alignFrames < 0 ? -alignFrames : 0
        let len = source.frameCount - sourceIn

        // Place the take at the playhead (+ any "later" alignment); if that would
        // overlap an existing clip, append it after the track's content instead.
        let playhead = max(0, playback.currentFrame) + delay
        let overlaps = project.tracks[i].clips.contains {
            playhead < $0.timelineEndFrame && (playhead + len) > $0.timelineStartFrame
        }
        let start = overlaps ? project.tracks[i].endFrame : playhead

        let clip = Clip(sourceID: source.id, sourceInFrame: sourceIn, sourceOutFrame: source.frameCount,
                        timelineStartFrame: start, effectChain: chain, name: name)
        project.tracks[i].clips.append(clip)
        playback.seek(to: start)   // playhead on the new take → play hears it immediately
    }

    func trackID(forClip clipID: UUID) -> UUID? {
        project.tracks.first { $0.clips.contains { $0.id == clipID } }?.id
    }

    /// Replaces a clip wherever it lives (used by the clip inspector) and pushes
    /// a live update to playback so per-clip filter edits are heard immediately.
    func commitClip(_ clip: Clip) {
        guard let tid = trackID(forClip: clip.id) else { return }
        updateClip(clip, onTrack: tid)
        playback.updateClipChain(clip.id, spec: clip.effectChain ?? .empty)
    }

    func deleteClipAnywhere(_ clipID: UUID) {
        guard let tid = trackID(forClip: clipID) else { return }
        deleteClip(clipID, fromTrack: tid)
    }

    func updateClip(_ clip: Clip, onTrack trackID: UUID) {
        guard let i = trackIndex(trackID),
              let ci = project.tracks[i].clips.firstIndex(where: { $0.id == clip.id }) else { return }
        project.tracks[i].clips[ci] = clip
    }

    func deleteClip(_ clipID: UUID, fromTrack trackID: UUID) {
        guard let i = trackIndex(trackID) else { return }
        let removed = project.tracks[i].clips.first { $0.id == clipID }
        project.tracks[i].clips.removeAll { $0.id == clipID }
        if let sid = removed?.sourceID { cleanupSourceIfUnused(sid) }
        if selectedClipID == clipID { clearSelection() }
    }

    func moveClip(_ clipID: UUID, toTrack targetTrackID: UUID, atFrame frame: AVAudioFramePosition) {
        project.moveClip(clipID, toTrack: targetTrackID, atFrame: frame)
    }

    @discardableResult
    func splitSelectedClip(atFrame frame: AVAudioFramePosition) -> Bool {
        guard let tid = selectedTrackID, let i = trackIndex(tid),
              let ci = project.tracks[i].clips.firstIndex(where: {
                  frame > $0.timelineStartFrame && frame < $0.timelineEndFrame
              }),
              let (left, right) = project.tracks[i].clips[ci].split(atTimelineFrame: frame) else { return false }
        project.tracks[i].clips.replaceSubrange(ci...ci, with: [left, right])
        return true
    }

    /// Splits a specific clip at an absolute timeline frame. Returns false if the
    /// frame isn't strictly inside the clip.
    @discardableResult
    func splitClip(_ clipID: UUID, atFrame frame: AVAudioFramePosition) -> Bool {
        guard let i = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let ci = project.tracks[i].clips.firstIndex(where: { $0.id == clipID }),
              let (left, right) = project.tracks[i].clips[ci].split(atTimelineFrame: frame) else { return false }
        project.tracks[i].clips.replaceSubrange(ci...ci, with: [left, right])
        selectedClipID = left.id
        return true
    }

    // MARK: Import

    func importAudio(from url: URL, intoTrack trackID: UUID?) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let dest = AppPaths.recordingsDirectory
            .appendingPathComponent("import-\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)

        let file = try AVAudioFile(forReading: dest)
        let source = AudioSource(fileName: dest.lastPathComponent,
                                 sampleRate: file.fileFormat.sampleRate, frameCount: file.length)
        appendClip(source: source, chain: nil, toTrack: trackID,
                   name: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: Transport

    func togglePlay() {
        if playback.isPlaying { playback.pause() }
        else {
            // Restart from the top if the playhead is at/after the end (or stale).
            let from = playback.currentFrame >= project.totalFrames ? 0 : playback.currentFrame
            playback.play(project: project, from: from)
        }
    }
    func stopPlayback() { playback.stop() }

    /// Moves the playhead (used by tap-to-seek on the timeline).
    func seek(toFrame frame: AVAudioFramePosition) {
        playback.seek(to: max(0, min(frame, project.totalFrames)))
    }

    // MARK: Source cleanup

    private func cleanupSourceIfUnused(_ sourceID: UUID) {
        let used = project.tracks.contains { $0.clips.contains { $0.sourceID == sourceID } }
        guard !used else { return }
        if let s = project.source(for: sourceID) { try? FileManager.default.removeItem(at: s.url) }
        project.sources.removeAll { $0.id == sourceID }
    }
}
