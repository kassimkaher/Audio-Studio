import XCTest
import AVFoundation
import Accelerate
#if os(macOS)
@testable import VoiceStudioMac
#else
@testable import VoiceStudio
#endif

/// Step 1 of Mobile Mic Link: the virtual-input pipeline (ring buffer +
/// `StreamInputNode` + transport contract), provable with no phone and no audio
/// hardware via offline manual rendering.
final class MobileLinkTests: XCTestCase {

    // MARK: Ring buffer

    func testRingBufferWriteThenRead() {
        let ring = AudioRingBuffer(capacity: 8)
        ring.write([1, 2, 3, 4])
        XCTAssertEqual(ring.available, 4)
        var out = [Float](repeating: -1, count: 4)
        let got = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 4) }
        XCTAssertEqual(got, 4)
        XCTAssertEqual(out, [1, 2, 3, 4])
        XCTAssertEqual(ring.available, 0)
    }

    func testRingBufferUnderrunPadsSilence() {
        let ring = AudioRingBuffer(capacity: 8)
        ring.write([5, 6])
        var out = [Float](repeating: 99, count: 5)
        let got = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 5) }
        XCTAssertEqual(got, 2, "only 2 real samples were available")
        XCTAssertEqual(out, [5, 6, 0, 0, 0], "missing frames are silence")
        XCTAssertEqual(ring.stats.underruns, 3)
    }

    func testRingBufferOverrunDropsOldest() {
        let ring = AudioRingBuffer(capacity: 4)
        ring.write([1, 2, 3, 4, 5, 6])      // 2 oldest dropped
        XCTAssertEqual(ring.available, 4)
        XCTAssertEqual(ring.stats.overruns, 2)
        var out = [Float](repeating: 0, count: 4)
        _ = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 4) }
        XCTAssertEqual(out, [3, 4, 5, 6], "kept the newest 4 samples")
    }

    // MARK: Frame wire format

    func testAudioFrameRoundTrips() {
        let frame = AudioFrame(sequence: 42, samples: [0, 0.5, -0.5, 1, -1, 0.25])
        let decoded = AudioFrame.decode(frame.encoded())
        XCTAssertEqual(decoded, frame)
    }

    func testAudioFrameDecodeRejectsTruncated() {
        XCTAssertNil(AudioFrame.decode(Data([1, 2, 3])))
    }

    // MARK: Synthetic transport

    func testSyntheticTransportProducesTone() {
        let t = SyntheticToneTransport(sampleRate: 48_000, frequency: 440, frameSize: 480)
        let f = t.nextFrame()
        XCTAssertEqual(f.samples.count, 480)
        var peak: Float = 0
        f.samples.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &peak, vDSP_Length($0.count)) }
        XCTAssertGreaterThan(peak, 0.9, "sine should reach near full scale")
        XCTAssertEqual(t.nextFrame().sequence, 1, "sequence advances")
    }

    // MARK: End-to-end virtual input (offline render — no hardware)

    func testStreamInputNodeRendersEnqueuedAudio() throws {
        let node = StreamInputNode(sampleRate: 48_000, jitterSeconds: 2.0)
        let engine = AVAudioEngine()
        engine.attach(node.sourceNode)
        engine.connect(node.sourceNode, to: engine.mainMixerNode, format: node.format)

        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
        try engine.start()

        // Enqueue 1s of 440 Hz tone via the transport → node pipeline.
        let transport = SyntheticToneTransport(sampleRate: 48_000, frameSize: 4800)
        node.bind(to: transport)
        for _ in 0..<10 { transport.onFrame?(transport.nextFrame()) }   // 10 × 4800 = 48000 samples
        XCTAssertGreaterThan(node.bufferedFrames, 40_000)

        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var peak: Float = 0
        var rendered = 0
        while rendered < 48_000 {
            let status = try engine.renderOffline(min(4096, AVAudioFrameCount(48_000 - rendered)), to: out)
            guard status == .success, out.frameLength > 0 else { break }
            if let ch = out.floatChannelData?[0] {
                var p: Float = 0
                vDSP_maxmgv(ch, 1, &p, vDSP_Length(out.frameLength))
                peak = max(peak, p)
            }
            rendered += Int(out.frameLength)
        }
        engine.stop()

        XCTAssertGreaterThan(peak, 0.1, "virtual input did not render the enqueued tone")
    }
}
