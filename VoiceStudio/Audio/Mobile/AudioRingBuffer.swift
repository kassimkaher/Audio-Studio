import Foundation
import os

/// A bounded single-producer / single-consumer jitter buffer of mono `Float`
/// samples, bridging the network thread (producer) and the audio render thread
/// (consumer) for `StreamInputNode`.
///
/// - The producer (`write`) drops the **oldest** samples on overrun (the stream
///   is faster than playback) and counts it.
/// - The consumer (`read`) pads with **silence** on underrun (the stream is
///   slower / stalled) and counts it — so the render block never blocks and the
///   engine never glitches into garbage.
///
/// Access is guarded by an `OSAllocatedUnfairLock`; critical sections are only
/// index arithmetic + a copy, so contention is negligible. (A later revision can
/// swap in true lock-free atomics once the deployment target allows it.)
final class AudioRingBuffer {
    private let capacity: Int
    private let storage: UnsafeMutableBufferPointer<Float>

    private struct State {
        var writeIndex = 0
        var readIndex = 0
        var filled = 0
        var underruns = 0
        var overruns = 0
        var totalWritten = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0)
    }
    deinit { storage.deallocate() }

    // MARK: Producer

    @discardableResult
    func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return 0 }
            return write(base, count: buf.count)
        }
    }

    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return state.withLock { s in
            for i in 0..<count {
                if s.filled >= capacity {
                    // Overrun: discard the oldest sample to make room.
                    s.readIndex = (s.readIndex + 1) % capacity
                    s.filled -= 1
                    s.overruns += 1
                }
                storage[s.writeIndex] = src[i]
                s.writeIndex = (s.writeIndex + 1) % capacity
                s.filled += 1
            }
            s.totalWritten += count
            return count
        }
    }

    // MARK: Consumer (audio render thread)

    /// Fills `count` frames into `dst`; missing frames are written as silence.
    /// Returns the number of *real* (non-silence) frames delivered.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return state.withLock { s in
            var delivered = 0
            for i in 0..<count {
                if s.filled > 0 {
                    dst[i] = storage[s.readIndex]
                    s.readIndex = (s.readIndex + 1) % capacity
                    s.filled -= 1
                    delivered += 1
                } else {
                    dst[i] = 0
                    s.underruns += 1
                }
            }
            return delivered
        }
    }

    // MARK: Introspection

    var available: Int { state.withLock { $0.filled } }
    var totalWritten: Int { state.withLock { $0.totalWritten } }
    var stats: (underruns: Int, overruns: Int) { state.withLock { ($0.underruns, $0.overruns) } }

    func reset() {
        state.withLock { s in s = State() }
        storage.update(repeating: 0)
    }
}
