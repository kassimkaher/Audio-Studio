import XCTest
#if os(macOS)
@testable import VoiceStudioMac
#else
@testable import VoiceStudio
#endif

/// Covers the model logic behind the unified DAW board: record-arm focus,
/// transient `isArmed` (never persisted), capture-target resolution, and
/// clip fade/gain mutation.
@MainActor
final class DAWBoardTests: XCTestCase {
    private func editor() -> ProjectEditorViewModel {
        ProjectEditorViewModel(project: .makeDefault(name: "T"), env: AppEnvironment())
    }

    func testArmIsExclusiveAndSelects() {
        let e = editor()
        let t1 = e.project.tracks[0].id
        let t2 = e.project.addTrack()
        e.toggleArm(t2)
        XCTAssertTrue(e.track(t2)?.isArmed ?? false)
        XCTAssertFalse(e.track(t1)?.isArmed ?? true)
        XCTAssertEqual(e.selectedTrackID, t2)
        XCTAssertEqual(e.captureTargetID, t2)
        // Arming another disarms the first.
        e.toggleArm(t1)
        XCTAssertTrue(e.track(t1)?.isArmed ?? false)
        XCTAssertFalse(e.track(t2)?.isArmed ?? true)
        // Toggling the armed track disarms it; target falls back to selection.
        e.toggleArm(t1)
        XCTAssertFalse(e.track(t1)?.isArmed ?? true)
        XCTAssertNotNil(e.captureTargetID)
    }

    func testIsArmedIsTransientAcrossCoding() throws {
        var p = Project.makeDefault()
        p.tracks[0].isArmed = true
        let data = try JSONEncoder().encode(p)
        let restored = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertFalse(restored.tracks[0].isArmed, "isArmed must not persist")
    }

    func testBilingualDefaultNames() {
        var p = Project.makeDefault()
        XCTAssertEqual(p.tracks[0].name, "Lead Lane")
        let bg = p.addTrack(kind: .background)
        XCTAssertTrue(p.tracks.first { $0.id == bg }!.name.contains("ردّة"))
    }

    func testGlobalClipboardPastesAcrossProjects() {
        let env = AppEnvironment()
        let e1 = ProjectEditorViewModel(project: .makeDefault(), env: env)
        let src = AudioSource(fileName: "x.wav", sampleRate: 48000, frameCount: 48000)
        let clip = Clip(sourceID: src.id, sourceInFrame: 0, sourceOutFrame: 48000, timelineStartFrame: 0)
        var t = e1.project.tracks[0]; t.clips = [clip]; e1.project.tracks[0] = t
        e1.project.sources.append(src)
        e1.selectedTrackID = t.id; e1.selectedClipID = clip.id
        e1.copySelection()

        // A different project (same process) pastes the same clip + re-registers source.
        let e2 = ProjectEditorViewModel(project: .makeDefault(), env: env)
        e2.selectedTrackID = e2.project.tracks[0].id
        let before = e2.project.tracks[0].clips.count
        e2.pasteClipboard()
        XCTAssertEqual(e2.project.tracks[0].clips.count, before + 1)
        XCTAssertTrue(e2.project.sources.contains { $0.id == src.id })
    }

    func testEffectChainIsolationAcrossTracks() {
        let e = editor()
        let t1 = e.project.tracks[0].id
        let t2 = e.project.addTrack()
        e.updateTrackChain(EffectChainSpec(stages: [EffectStageSpec(kind: .reverb)], wetDryMix: 1, intensity: 1), forTrack: t1)
        // Editing t1 leaves t2 fully untouched (value-type deep isolation).
        XCTAssertEqual(e.track(t1)?.effectChain.stages.first?.kind, .reverb)
        XCTAssertTrue(e.track(t2)?.effectChain.stages.isEmpty ?? false)
        e.updateTrackChain(EffectChainSpec(stages: [], wetDryMix: 0.3, intensity: 1), forTrack: t1)
        XCTAssertEqual(e.track(t1)?.effectChain.wetDryMix, 0.3)
        XCTAssertNotEqual(e.track(t2)?.effectChain.wetDryMix, 0.3)
    }

    func testUndoRedoForDeleteAndPaste() {
        let e = editor()
        let tid = e.project.tracks[0].id
        let src = AudioSource(fileName: "u.wav", sampleRate: 48000, frameCount: 48000)
        let clip = Clip(sourceID: src.id, sourceInFrame: 0, sourceOutFrame: 48000, timelineStartFrame: 0)
        var t = e.project.tracks[0]; t.clips = [clip]; e.project.tracks[0] = t
        e.project.sources.append(src)
        XCTAssertFalse(e.canUndo)

        // Delete → undo restores → redo removes again.
        e.deleteClip(clip.id, fromTrack: tid)
        XCTAssertEqual(e.track(tid)?.clips.count, 0)
        XCTAssertTrue(e.canUndo)
        e.undo()
        XCTAssertEqual(e.track(tid)?.clips.count, 1)
        XCTAssertTrue(e.canRedo)
        e.redo()
        XCTAssertEqual(e.track(tid)?.clips.count, 0)
    }

    func testClipFadeAndGainMutation() {
        let e = editor()
        let src = AudioSource(fileName: "a.wav", sampleRate: 48000, frameCount: 48000)
        let clip = Clip(sourceID: src.id, sourceInFrame: 0, sourceOutFrame: 48000, timelineStartFrame: 0)
        var track = e.project.tracks[0]; track.clips = [clip]; e.project.tracks[0] = track
        e.project.sources.append(src)
        var c = clip; c.fadeIn = 0.3; c.fadeOut = 0.5; c.gain = 1.6
        e.updateClip(c, onTrack: track.id)
        let stored = e.clip(clip.id)?.clip
        XCTAssertEqual(stored?.fadeIn ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(stored?.fadeOut ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(stored?.gain ?? 0, 1.6, accuracy: 0.001)
    }
}
