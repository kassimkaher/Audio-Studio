import XCTest
#if os(macOS)
@testable import VoiceStudioMac
#else
@testable import VoiceStudio
#endif

final class ClipTests: XCTestCase {
    private func makeClip(in: Int64 = 0, out: Int64 = 48_000, start: Int64 = 0) -> Clip {
        Clip(sourceID: UUID(), sourceInFrame: `in`, sourceOutFrame: out, timelineStartFrame: start)
    }

    func testFrameLengthAndTimelineEnd() {
        let clip = makeClip(in: 1000, out: 5000, start: 2000)
        XCTAssertEqual(clip.frameLength, 4000)
        XCTAssertEqual(clip.timelineEndFrame, 6000)
    }

    func testSplitProducesContiguousPieces() {
        let clip = makeClip(in: 0, out: 48_000, start: 0)        // 0...48000 on timeline
        let result = clip.split(atTimelineFrame: 12_000)
        let (left, right) = try! XCTUnwrap(result)

        // Pieces meet exactly at the split point with no gap/overlap.
        XCTAssertEqual(left.timelineStartFrame, 0)
        XCTAssertEqual(left.timelineEndFrame, 12_000)
        XCTAssertEqual(right.timelineStartFrame, 12_000)
        XCTAssertEqual(right.timelineEndFrame, 48_000)

        // Combined length equals the original.
        XCTAssertEqual(left.frameLength + right.frameLength, clip.frameLength)

        // Source frames are contiguous across the split.
        XCTAssertEqual(left.sourceOutFrame, right.sourceInFrame)
    }

    func testSplitRespectsTimelineOffset() {
        let clip = makeClip(in: 5_000, out: 25_000, start: 10_000) // timeline 10000...30000
        let (left, right) = try! XCTUnwrap(clip.split(atTimelineFrame: 18_000))
        XCTAssertEqual(left.frameLength, 8_000)                    // 18000 - 10000
        XCTAssertEqual(left.sourceOutFrame, 13_000)               // 5000 + 8000
        XCTAssertEqual(right.sourceInFrame, 13_000)
        XCTAssertEqual(right.sourceOutFrame, 25_000)
    }

    func testSplitOutsideBoundsReturnsNil() {
        let clip = makeClip(in: 0, out: 48_000, start: 10_000)
        XCTAssertNil(clip.split(atTimelineFrame: 10_000)) // at start edge
        XCTAssertNil(clip.split(atTimelineFrame: 58_000)) // at end edge
        XCTAssertNil(clip.split(atTimelineFrame: 5_000))  // before clip
    }
}

final class ProjectMixTests: XCTestCase {
    private func makeProject(mute: [Bool], solo: [Bool]) -> Project {
        var tracks: [Track] = []
        for i in 0..<mute.count {
            tracks.append(Track(name: "T\(i)", kind: i == 0 ? .vocal : .background,
                                isMuted: mute[i], isSoloed: solo[i]))
        }
        return Project(tracks: tracks)
    }

    func testMutedTrackIsInaudible() {
        let p = makeProject(mute: [true, false], solo: [false, false])
        XCTAssertFalse(p.isAudible(p.tracks[0]))
        XCTAssertTrue(p.isAudible(p.tracks[1]))
    }

    func testSoloSilencesNonSoloedTracks() {
        let p = makeProject(mute: [false, false], solo: [false, true])
        XCTAssertFalse(p.isAudible(p.tracks[0]))
        XCTAssertTrue(p.isAudible(p.tracks[1]))
    }

    func testMuteWinsOverSolo() {
        let p = makeProject(mute: [true, false], solo: [true, false])
        // Track 0 is soloed but also muted → inaudible.
        XCTAssertFalse(p.isAudible(p.tracks[0]))
    }

    func testTotalFramesIsLongestTrack() {
        var p = makeProject(mute: [false, false], solo: [false, false])
        p.tracks[0].clips = [Clip(sourceID: UUID(), sourceInFrame: 0, sourceOutFrame: 1000, timelineStartFrame: 0)]
        p.tracks[1].clips = [Clip(sourceID: UUID(), sourceInFrame: 0, sourceOutFrame: 1000, timelineStartFrame: 5000)]
        XCTAssertEqual(p.totalFrames, 6000)
    }
}

final class PresetSerializationTests: XCTestCase {
    func testEveryPresetRoundTrips() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for preset in PresetLibrary.all {
            let data = try encoder.encode(preset.chain)
            let restored = try decoder.decode(EffectChainSpec.self, from: data)
            XCTAssertEqual(restored, preset.chain, "Preset \(preset.id) did not round-trip")
        }
    }

    func testQuranPresetHasMosqueReverbAndEcho() {
        let kinds = PresetLibrary.quran.chain.stages.map(\.kind)
        XCTAssertTrue(kinds.contains(.reverb))
        XCTAssertTrue(kinds.contains(.multiTapDelay))
    }

    func testEveryPresetReservesMLSlotDisabled() {
        for preset in PresetLibrary.all {
            let mlStage = preset.chain.stages.first { $0.kind == .mlVoiceConversion }
            XCTAssertNotNil(mlStage, "\(preset.id) missing ML slot")
            XCTAssertEqual(mlStage?.isEnabled, false, "\(preset.id) ML slot should be disabled in Phase 1")
        }
    }

    func testProjectRoundTrips() throws {
        let project = Project.makeDefault()
        let data = try JSONEncoder().encode(project)
        let restored = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(restored.tracks.count, project.tracks.count)
        XCTAssertEqual(restored.sampleRate, project.sampleRate)
    }
}
