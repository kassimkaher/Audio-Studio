import XCTest
#if os(macOS)
@testable import VoiceStudioMac
#else
@testable import VoiceStudio
#endif

final class ProjectEditOpsTests: XCTestCase {
    private func project() -> Project {
        let src = AudioSource(fileName: "a.wav", sampleRate: 48000, frameCount: 1000)
        let clip = Clip(sourceID: src.id, sourceInFrame: 0, sourceOutFrame: 1000, timelineStartFrame: 0, name: "Take")
        var t = Track(name: "Track 1", kind: .vocal); t.clips = [clip]
        return Project(name: "P", tracks: [t], sources: [src])
    }

    func testDuplicateTrackInsertsCopyBelowWithFreshIDs() {
        var p = project()
        let originalID = p.tracks[0].id
        let originalClipID = p.tracks[0].clips[0].id
        let newID = p.duplicateTrack(originalID)
        XCTAssertEqual(p.tracks.count, 2)
        XCTAssertEqual(p.tracks[1].id, newID)
        XCTAssertNotEqual(p.tracks[1].id, originalID)
        XCTAssertNotEqual(p.tracks[1].clips[0].id, originalClipID)   // fresh clip id
        XCTAssertEqual(p.tracks[1].clips[0].frameLength, 1000)        // same audio region
    }

    func testDuplicateClipPlacesCopyAfterOriginalSameTrack() {
        var p = project()
        let clipID = p.tracks[0].clips[0].id
        let end = p.tracks[0].clips[0].timelineEndFrame
        let newID = p.duplicateClip(clipID)
        XCTAssertEqual(p.tracks[0].clips.count, 2)
        let copy = p.tracks[0].clips.first { $0.id == newID }
        XCTAssertEqual(copy?.timelineStartFrame, end)                 // no overlap
        XCTAssertNotEqual(newID, clipID)
    }

    func testRenameTrack() {
        var p = project()
        p.renameTrack(p.tracks[0].id, to: "Lead Vocal")
        XCTAssertEqual(p.tracks[0].name, "Lead Vocal")
    }
}
