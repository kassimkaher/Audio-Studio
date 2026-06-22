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

    // MARK: Undo / redo (snapshot-based; ⌘Z / ⌘⇧Z)
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var isRestoring = false
    private let undoLimit = 50

    let env: AppEnvironment
    private var saveWork: DispatchWorkItem?

    /// Paste availability (reads the process-wide clipboard).
    var canPaste: Bool { ClipboardContext.clip != nil || ClipboardContext.track != nil }

    init(project: Project, env: AppEnvironment) {
        self.project = project
        self.env = env
    }

    var playback: PlaybackService { env.playbackService }
    var store: ProjectStore { env.projectStore }
    var sampleRate: Double { project.sampleRate }

    // MARK: Undo / redo

    /// Snapshot the project *before* a discrete edit (split/delete/paste/…).
    func pushUndo() {
        guard !isRestoring else { return }
        undoStack.append(project)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true; canRedo = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        restore(previous)
        canUndo = !undoStack.isEmpty; canRedo = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        restore(next)
        canRedo = !redoStack.isEmpty; canUndo = true
    }

    private func restore(_ snapshot: Project) {
        isRestoring = true
        project = snapshot
        isRestoring = false
        if let cid = selectedClipID, clip(cid) == nil { selectedClipID = nil }
        if let tid = selectedTrackID, track(tid) == nil { selectedTrackID = nil }
        playback.applyMix(from: project)   // keep live mix consistent after a restore
    }

    // MARK: Persistence (debounced autosave)

    /// True under XCTest — so unit tests never write throwaway projects into the
    /// user's real library (clone-and-delete is the manual-testing convention).
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    private func scheduleSave() {
        guard !Self.isTesting else { return }
        saveWork?.cancel()
        let snapshot = project
        let work = DispatchWorkItem { [store] in try? store.save(snapshot) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        guard !Self.isTesting else { return }
        saveWork?.cancel()
        try? store.save(project)
    }

    // MARK: Timeline geometry

    /// Horizontal zoom bounds (pixels per second of audio).
    static let minPixelsPerSecond: CGFloat = 8
    static let maxPixelsPerSecond: CGFloat = 1200

    /// Pinch-to-zoom the timeline (two-finger magnify, Audition-style).
    func zoomTimeline(by factor: CGFloat) {
        let next = pixelsPerSecond * factor
        pixelsPerSecond = min(max(next, Self.minPixelsPerSecond), Self.maxPixelsPerSecond)
    }

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

    func addTrack() { pushUndo(); project.addTrack() }

    @discardableResult
    func addTrackReturningID() -> UUID { project.addTrack() }

    func removeTrack(_ id: UUID) {
        pushUndo()
        // Free files owned solely by clips on this track.
        if let idx = trackIndex(id) {
            let sourceIDs = project.tracks[idx].clips.map(\.sourceID)
            project.removeTrack(id)
            sourceIDs.forEach { cleanupSourceIfUnused($0) }
        }
        if selectedTrackID == id { clearSelection() }
    }

    /// The track the next take will be captured into: the armed track, else the
    /// current selection, else the first track.
    var captureTargetID: UUID? {
        project.tracks.first(where: \.isArmed)?.id ?? selectedTrackID ?? project.tracks.first?.id
    }

    /// Record-arm a track exclusively (arming also selects it as the focus).
    /// Tapping the armed track again disarms it.
    func toggleArm(_ id: UUID) {
        let alreadyArmed = project.tracks.first(where: { $0.id == id })?.isArmed ?? false
        for i in project.tracks.indices { project.tracks[i].isArmed = false }
        if !alreadyArmed, let i = trackIndex(id) {
            project.tracks[i].isArmed = true
            selectedTrackID = id
            selectedClipID = nil
        }
    }

    func renameProject(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        project.name = trimmed
    }

    func renameTrack(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pushUndo()
        project.renameTrack(id, to: trimmed)
    }

    /// Duplicates a track (clips + effects) directly below it.
    func duplicateTrack(_ id: UUID) {
        pushUndo()
        if let newID = project.duplicateTrack(id) { selectedTrackID = newID; selectedClipID = nil }
    }

    /// Duplicates a clip onto the same track, after the original, and selects it.
    func duplicateClip(_ clipID: UUID) {
        pushUndo()
        if let newID = project.duplicateClip(clipID) { selectedClipID = newID }
    }

    /// Duplicates a clip onto a brand-new track at the SAME timeline position, so
    /// the copy plays in parallel with the original. Returns/selects the copy.
    func duplicateClipToNewTrack(_ clipID: UUID) {
        guard let found = clip(clipID) else { return }
        pushUndo()
        let newTrackID = project.addTrack(name: "Track \(project.tracks.count + 1)")
        guard let i = trackIndex(newTrackID) else { return }
        let copy = found.clip.duplicated(timelineStartFrame: found.clip.timelineStartFrame)
        project.tracks[i].clips.append(copy)
        selectedTrackID = newTrackID
        selectedClipID = copy.id
    }

    /// Live volume-riding while dragging the gain envelope: applies instantly to
    /// the playing clip's node (heard immediately), without a graph rebuild.
    func setClipGainLive(_ clipID: UUID, _ gain: Float) {
        playback.setClipGain(clipID, gain)
    }

    /// Shifts a clip along the timeline by `deltaFrames` (clamped at 0).
    func nudgeClip(_ clipID: UUID, byFrames deltaFrames: AVAudioFramePosition) {
        guard let i = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let ci = project.tracks[i].clips.firstIndex(where: { $0.id == clipID }) else { return }
        let newStart = max(0, project.tracks[i].clips[ci].timelineStartFrame + deltaFrames)
        pushUndo()
        project.tracks[i].clips[ci].timelineStartFrame = newStart
    }

    /// Moves a clip's start to an absolute timeline frame (e.g. the playhead).
    func setClipStart(_ clipID: UUID, toFrame frame: AVAudioFramePosition) {
        guard let i = project.tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let ci = project.tracks[i].clips.firstIndex(where: { $0.id == clipID }) else { return }
        pushUndo()
        project.tracks[i].clips[ci].timelineStartFrame = max(0, frame)
    }

    // MARK: Workspace sidebar — apply profile / IR to the current selection

    /// Applies an effect chain (Vocal Profile / Mode) to the selected clip, or
    /// else the selected track's master chain.
    func applyChainToSelection(_ chain: EffectChainSpec) {
        if let cid = selectedClipID, var found = clip(cid)?.clip {
            found.effectChain = chain
            commitClip(found)
        } else if let tid = selectedTrackID {
            updateTrackChain(chain, forTrack: tid)
        }
    }

    /// Loads an IR space onto the selection's convolution stage (adding one if
    /// the chain has none), so clicking an IR Space "applies" it.
    func applyIR(_ id: String) {
        func patched(_ spec: EffectChainSpec) -> EffectChainSpec {
            var s = spec
            if let i = s.stages.firstIndex(where: { $0.kind == .convolutionReverb }) {
                var sp = s.stages[i].stringParams ?? [:]
                sp[ParamKeys.ir] = id
                s.stages[i].stringParams = sp
            } else {
                s.stages.append(EffectStageSpec(kind: .convolutionReverb,
                                                params: [ParamKeys.mix: 0.4],
                                                stringParams: [ParamKeys.ir: id]))
            }
            return s
        }
        if let cid = selectedClipID, var c = clip(cid)?.clip {
            c.effectChain = patched(c.effectChain ?? EffectChainSpec())
            commitClip(c)
        } else if let tid = selectedTrackID, let t = track(tid) {
            updateTrackChain(patched(t.effectChain), forTrack: tid)
        }
    }

    // MARK: Copy / paste / duplicate (keyboard + menus)

    /// ⌘C — copy the selected clip (with its source so it survives cross-project),
    /// or (if none) the selected track and all its sources.
    func copySelection() {
        if let cid = selectedClipID, let found = clip(cid) {
            ClipboardContext.clip = found.clip
            ClipboardContext.clipSource = found.source
            ClipboardContext.track = nil
        } else if let tid = selectedTrackID, let t = track(tid) {
            ClipboardContext.track = t
            ClipboardContext.trackSources = t.clips.compactMap { project.source(for: $0.sourceID) }
            ClipboardContext.clip = nil
        }
    }

    /// ⌘V — paste a non-destructive duplicate onto the **selected target track**,
    /// positioned exactly at the current playhead. Works across tracks and
    /// projects (the underlying source file is re-registered if missing).
    func pasteClipboard() {
        guard canPaste else { return }
        pushUndo()
        if let c = ClipboardContext.clip {
            if let src = ClipboardContext.clipSource, !project.sources.contains(where: { $0.id == src.id }) {
                project.sources.append(src)                    // cross-project: re-register source
            }
            let targetID = selectedTrackID
                ?? selectedClipID.flatMap { trackID(ofClip: $0) }
                ?? project.tracks.first?.id
            guard let tid = targetID, let i = trackIndex(tid) else { return }
            let copy = c.duplicated(timelineStartFrame: max(0, playback.currentFrame))  // exactly at playhead
            project.tracks[i].clips.append(copy)
            selectedClipID = copy.id
        } else if let t = ClipboardContext.track {
            for s in ClipboardContext.trackSources where !project.sources.contains(where: { $0.id == s.id }) {
                project.sources.append(s)
            }
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
    /// Returns where the take landed (`start`) and its `length` in frames, so
    /// callers (e.g. the Live Audience commit) can align companion clips.
    @discardableResult
    func appendClip(source: AudioSource, chain: EffectChainSpec?, toTrack trackID: UUID?,
                    name: String, alignFrames: AVAudioFramePosition = 0)
        -> (start: AVAudioFramePosition, length: AVAudioFramePosition) {
        pushUndo()
        if !project.sources.contains(where: { $0.id == source.id }) {
            project.sources.append(source)
        }
        let targetID = trackID ?? project.tracks.first?.id ?? project.addTrack()
        guard let i = trackIndex(targetID) else { return (0, 0) }

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
        return (start, len)
    }

    /// Finds (or creates) a background "atmosphere" track by name.
    func backgroundTrackID(named name: String) -> UUID {
        if let t = project.tracks.first(where: { $0.kind == .background && $0.name == name }) { return t.id }
        return project.addTrack(kind: .background, name: name)
    }

    /// Registers `source` (if new) and appends prebuilt clips at their own
    /// timeline positions to a track — used to tile the crowd bed under a take.
    func addClips(_ clips: [Clip], source: AudioSource, toTrack trackID: UUID, trackVolume: Float? = nil) {
        guard !clips.isEmpty else { return }
        if !project.sources.contains(where: { $0.id == source.id }) {
            project.sources.append(source)
        }
        guard let i = trackIndex(trackID) else { return }
        project.tracks[i].clips.append(contentsOf: clips)
        if let v = trackVolume { project.tracks[i].volume = v }
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
        pushUndo()
        let removed = project.tracks[i].clips.first { $0.id == clipID }
        project.tracks[i].clips.removeAll { $0.id == clipID }
        if let sid = removed?.sourceID { cleanupSourceIfUnused(sid) }
        if selectedClipID == clipID { clearSelection() }
    }

    func moveClip(_ clipID: UUID, toTrack targetTrackID: UUID, atFrame frame: AVAudioFramePosition) {
        pushUndo()
        project.moveClip(clipID, toTrack: targetTrackID, atFrame: frame)
    }

    @discardableResult
    func splitSelectedClip(atFrame frame: AVAudioFramePosition) -> Bool {
        guard let tid = selectedTrackID, let i = trackIndex(tid),
              let ci = project.tracks[i].clips.firstIndex(where: {
                  frame > $0.timelineStartFrame && frame < $0.timelineEndFrame
              }),
              let (left, right) = project.tracks[i].clips[ci].split(atTimelineFrame: frame) else { return false }
        pushUndo()
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
        pushUndo()
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
