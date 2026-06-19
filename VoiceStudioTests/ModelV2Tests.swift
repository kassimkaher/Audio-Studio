import XCTest
import AVFoundation
#if os(macOS)
@testable import VoiceStudioMac
#else
@testable import VoiceStudio
#endif

final class ClipEffectChainTests: XCTestCase {
    func testClipRoundTripsWithEffectChain() throws {
        var clip = Clip(sourceID: UUID(), sourceInFrame: 0, sourceOutFrame: 1000,
                        timelineStartFrame: 0, name: "Take")
        clip.effectChain = PresetLibrary.quran.chain
        let data = try JSONEncoder().encode(clip)
        let restored = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(restored.effectChain, clip.effectChain)
        XCTAssertEqual(restored.name, "Take")
    }

    func testOldClipJSONDecodesWithDefaults() throws {
        // JSON predating `name`/`effectChain`.
        let json = """
        {"id":"\(UUID().uuidString)","sourceID":"\(UUID().uuidString)",
         "sourceInFrame":0,"sourceOutFrame":2000,"timelineStartFrame":100,
         "gain":1.0,"fadeIn":0,"fadeOut":0}
        """.data(using: .utf8)!
        let clip = try JSONDecoder().decode(Clip.self, from: json)
        XCTAssertNil(clip.effectChain)
        XCTAssertEqual(clip.name, "Clip")
        XCTAssertEqual(clip.frameLength, 2000)
    }
}

final class ProjectTrackOpsTests: XCTestCase {
    func testMakeDefaultHasOneTrack() {
        XCTAssertEqual(Project.makeDefault().tracks.count, 1)
    }

    func testAddAndRemoveTrack() {
        var p = Project.makeDefault()
        let id = p.addTrack()
        XCTAssertEqual(p.tracks.count, 2)
        p.removeTrack(id)
        XCTAssertEqual(p.tracks.count, 1)
    }

    func testMoveClipBetweenTracks() {
        var p = Project.makeDefault()
        let t2 = p.addTrack()
        let clip = Clip(sourceID: UUID(), sourceInFrame: 0, sourceOutFrame: 1000, timelineStartFrame: 0)
        p.tracks[0].clips.append(clip)

        p.moveClip(clip.id, toTrack: t2, atFrame: 5000)

        XCTAssertTrue(p.tracks[0].clips.isEmpty)
        XCTAssertEqual(p.tracks[1].clips.count, 1)
        XCTAssertEqual(p.tracks[1].clips[0].timelineStartFrame, 5000)
    }
}

final class ProjectStoreDeleteTests: XCTestCase {
    func testDeleteRemovesProjectAndSourceFiles() throws {
        let store = ProjectStore()

        // Create a real source file on disk.
        let fileName = "test-\(UUID().uuidString).wav"
        let url = AppPaths.recordingsDirectory.appendingPathComponent(fileName)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800)!
        buf.frameLength = 4800
        try file.write(from: buf)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let source = AudioSource(fileName: fileName, sampleRate: 48000, frameCount: 4800)
        var project = Project.makeDefault(name: "ToDelete")
        project.sources = [source]
        try store.save(project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: project).path))

        store.delete(project)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "source file should be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: project).path),
                       "project json should be deleted")
    }
}
