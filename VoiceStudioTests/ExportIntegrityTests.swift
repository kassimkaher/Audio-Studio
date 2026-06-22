import XCTest
import AVFoundation
#if os(macOS)
@testable import VoiceStudioMac
#else
@testable import VoiceStudio
#endif

/// Renders a CLEAN sine through the real `MixdownRenderer` and counts sample
/// discontinuities, to catch export corruption (ticks/noise) — especially for
/// 44.1 kHz sources inside a 48 kHz project.
@MainActor
final class ExportIntegrityTests: XCTestCase {

    private func makeTone(sampleRate: Double, seconds: Double = 2.0) throws -> AudioSource {
        let name = "exptone-\(UUID().uuidString).wav"
        let url = AppPaths.recordingsDirectory.appendingPathComponent(name)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) { ch[i] = 0.3 * sinf(2 * .pi * 220 * Float(i) / Float(sampleRate)) }
        try file.write(from: buf)
        return AudioSource(fileName: name, sampleRate: sampleRate, frameCount: AVAudioFramePosition(frames))
    }

    private func renderSamples(sourceRate: Double) async throws -> [Float] {
        let src = try makeTone(sampleRate: sourceRate)
        let clip = Clip(sourceID: src.id, sourceInFrame: 0, sourceOutFrame: src.frameCount, timelineStartFrame: 0)
        var track = Track(name: "T", kind: .vocal); track.clips = [clip]
        let project = Project(name: "exp", sampleRate: 48_000, tracks: [track], sources: [src])
        let url = try await MixdownRenderer().render(project: project, format: .wav)
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let ch = buf.floatChannelData![0]
        let out = Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: src.url)
        return out
    }

    private func report(_ s: [Float], label: String) -> Int {
        var ticks = 0
        for i in 1..<s.count where abs(s[i] - s[i-1]) > 0.05 { ticks += 1 }
        let peak = s.map { abs($0) }.max() ?? 0
        print("[\(label)] samples=\(s.count) peak=\(peak) ticks(>0.05 jump)=\(ticks)")
        return ticks
    }

    func testExport48kSourceIsClean() async throws {
        let ticks = report(try await renderSamples(sourceRate: 48_000), label: "48k→48k")
        XCTAssertLessThan(ticks, 10, "48k export should be clean")
    }

    func testExport44kSourceIsClean() async throws {
        let ticks = report(try await renderSamples(sourceRate: 44_100), label: "44.1k→48k")
        XCTAssertLessThan(ticks, 10, "44.1k-into-48k export should be clean")
    }
}
