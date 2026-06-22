import Foundation
import AVFoundation

/// A virtual capture source: an `AVAudioSourceNode` whose render block pulls
/// streamed phone audio out of a jitter buffer. The DAW treats it exactly like a
/// hardware input — tap it, record it, meter it — but the samples arrive over the
/// network (or, in tests, from `SyntheticToneTransport`) instead of a mic.
///
/// Underruns render as silence (never a glitch); the producer side absorbs jitter
/// and clock drift via the ring buffer.
final class StreamInputNode {
    let format: AVAudioFormat
    private let ring: AudioRingBuffer

    /// The node to attach into an `AVAudioEngine` and connect downstream.
    private(set) lazy var sourceNode: AVAudioSourceNode = makeSourceNode()

    init(sampleRate: Double = 48_000, jitterSeconds: Double = 1.0) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        ring = AudioRingBuffer(capacity: max(1, Int(sampleRate * jitterSeconds)))
    }

    // MARK: Producer side (network / synthetic thread)

    func enqueue(_ samples: [Float]) { ring.write(samples) }
    func enqueue(_ frame: AudioFrame) { ring.write(frame.samples) }

    /// Connects a transport so its frames flow straight into the buffer.
    func bind(to transport: MobileLinkTransport) {
        transport.onFrame = { [weak self] frame in self?.enqueue(frame) }
    }

    // MARK: Diagnostics

    var bufferedFrames: Int { ring.available }
    var bufferedSeconds: Double { Double(ring.available) / format.sampleRate }
    /// Total samples ever received — used to detect a stalled stream (phone locked).
    var receivedSamples: Int { ring.totalWritten }
    var stats: (underruns: Int, overruns: Int) { ring.stats }
    func reset() { ring.reset() }

    // MARK: Render

    private func makeSourceNode() -> AVAudioSourceNode {
        let ring = self.ring
        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let n = Int(frameCount)
            for buffer in abl {
                guard let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                ring.read(into: ptr, count: n)
            }
            return noErr
        }
    }
}
