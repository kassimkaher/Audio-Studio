import XCTest
import AVFoundation
#if os(macOS)
@testable import VoiceStudioMac
#else
@testable import VoiceStudio
#endif

/// Verifies the playback engine actually renders (the playhead advances) when a
/// clip is added to a track — the real path behind "press play after recording".
@MainActor
final class PlaybackTests: XCTestCase {

    private func makeToneSource(seconds: Double = 1.0, sampleRate: Double = 48_000) throws -> AudioSource {
        let name = "tone-\(UUID().uuidString).wav"
        let url = AppPaths.recordingsDirectory.appendingPathComponent(name)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = 0.2 * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
        try file.write(from: buf)
        return AudioSource(fileName: name, sampleRate: sampleRate, frameCount: AVAudioFramePosition(frames))
    }

    func testPlaybackAdvancesAfterAddingClip() async throws {
        let session = AudioSessionManager()
        let playback = PlaybackService(sessionManager: session)

        let source = try makeToneSource()
        let clip = Clip(sourceID: source.id, sourceInFrame: 0, sourceOutFrame: source.frameCount,
                        timelineStartFrame: 0)
        var track = Track(name: "Vocal", kind: .vocal)
        track.clips = [clip]
        let project = Project(name: "T", sampleRate: 48_000, tracks: [track], sources: [source])

        playback.play(project: project, from: 0)
        // Let it render for a bit.
        try await Task.sleep(nanoseconds: 600_000_000)
        let advanced = playback.currentFrame
        playback.stop()
        try? FileManager.default.removeItem(at: source.url)

        XCTAssertTrue(playback.isPlaying == false || advanced > 0,
                      "Playback did not advance (currentFrame stayed 0) — engine not rendering")
        // Stronger expectation when an output device is available:
        XCTAssertGreaterThan(advanced, 0, "Playhead did not advance after play")
    }
}
