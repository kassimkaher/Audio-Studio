import XCTest
import AVFoundation
#if os(macOS)
@testable import VoiceStudioMac
#else
@testable import VoiceStudio
#endif

final class ConvolutionMathTests: XCTestCase {
    private func convolve(_ input: [Float], ir: [Float]) -> [Float] {
        let conv = DirectConvolver()
        conv.setIR(ir)
        var out = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { ip in
            out.withUnsafeMutableBufferPointer { op in
                conv.process(ip.baseAddress!, op.baseAddress!, input.count)
            }
        }
        return out
    }

    func testUnitImpulseIsIdentity() {
        let input: [Float] = [1, 2, 3, 4, 5]
        let out = convolve(input, ir: [1])
        XCTAssertEqual(out, input)
    }

    func testSingleSampleDelay() {
        // IR [0, 1] delays the signal by one sample.
        let out = convolve([1, 2, 3, 4], ir: [0, 1])
        XCTAssertEqual(out, [0, 1, 2, 3])
    }

    func testScaledImpulse() {
        let out = convolve([1, 2, 3], ir: [0.5])
        XCTAssertEqual(out, [0.5, 1.0, 1.5])
    }
}

final class ConvolutionSpecTests: XCTestCase {
    func testStageRoundTripsWithStringParams() throws {
        let stage = EffectStageSpec(kind: .convolutionReverb,
                                    params: [ParamKeys.mix: 0.4],
                                    stringParams: [ParamKeys.ir: "HussainiHall"])
        let data = try JSONEncoder().encode(stage)
        let restored = try JSONDecoder().decode(EffectStageSpec.self, from: data)
        XCTAssertEqual(restored.stringParams?[ParamKeys.ir], "HussainiHall")
        XCTAssertEqual(restored.param(ParamKeys.mix, default: 0), 0.4)
    }

    func testOldStageWithoutStringParamsDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","kind":"reverb","isEnabled":true,"params":{"mix":0.5}}
        """.data(using: .utf8)!
        let stage = try JSONDecoder().decode(EffectStageSpec.self, from: json)
        XCTAssertNil(stage.stringParams)
        XCTAssertEqual(stage.kind, .reverb)
    }

    func testSignaturePresetUsesConvolution() {
        let kinds = PresetLibrary.hussainiPro.chain.stages.map(\.kind)
        XCTAssertTrue(kinds.contains(.convolutionReverb))
        let conv = PresetLibrary.hussainiPro.chain.stages.first { $0.kind == .convolutionReverb }
        XCTAssertEqual(conv?.stringParams?[ParamKeys.ir], "HussainiHall")
    }
}

final class StyleTransferTests: XCTestCase {
    func testVoiceProfileMakesEQPlusConvolutionChain() {
        let chain = VoiceProfile.neutral.makeChain()
        let kinds = chain.stages.map(\.kind)
        XCTAssertTrue(kinds.contains(.parametricEQ))
        XCTAssertTrue(kinds.contains(.convolutionReverb))
    }

    @MainActor
    func testPlaybackThroughConvolutionRenders() throws {
        // A clip whose per-clip chain includes the custom convolution AU must
        // instantiate and render without crashing (playhead advances).
        let sr = 48_000.0
        let name = "ctone-\(UUID().uuidString).wav"
        let url = AppPaths.recordingsDirectory.appendingPathComponent(name)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(sr)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = 0.2 * sinf(2 * .pi * 440 * Float(i) / Float(sr)) }
        try file.write(from: buf)
        let source = AudioSource(fileName: name, sampleRate: sr, frameCount: AVAudioFramePosition(frames))

        var clip = Clip(sourceID: source.id, sourceInFrame: 0, sourceOutFrame: source.frameCount, timelineStartFrame: 0)
        clip.effectChain = EffectChainSpec(stages: [
            EffectStageSpec(kind: .convolutionReverb, params: [ParamKeys.mix: 0.5],
                            stringParams: [ParamKeys.ir: "HussainiHall"])
        ])
        var track = Track(name: "V", kind: .vocal); track.clips = [clip]
        let project = Project(name: "C", sampleRate: sr, tracks: [track], sources: [source])

        let playback = PlaybackService(sessionManager: AudioSessionManager())
        playback.play(project: project, from: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let advanced = playback.currentFrame
        playback.stop()
        try? FileManager.default.removeItem(at: url)
        XCTAssertGreaterThan(advanced, 0, "Playback through the convolution node did not render")
    }

    @MainActor
    func testStubStyleCapturePipelineSavesMode() async throws {
        let store = PresetStore()
        let before = store.presets.count
        let service = StyleCaptureService(generator: StubPresetGenerator(), presetStore: store)
        let mode = try await service.captureMode(from: URL(fileURLWithPath: "/tmp/ref.wav"), named: "Captured")
        XCTAssertEqual(store.presets.count, before + 1)
        XCTAssertTrue(mode.chain.stages.contains { $0.kind == .convolutionReverb })
        store.delete(mode.id)
    }
}
