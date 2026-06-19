import Foundation
import AVFoundation
import Combine
import Accelerate

/// Collects a rolling waveform for live display.
///
/// The audio-thread `ingest(_:)` does only cheap vDSP peak math and writes into a
/// lock-guarded ring buffer (no allocation, no UI). A main-thread timer coalesces
/// snapshots into `@Published levels` at ~30 Hz so SwiftUI redraws stay cheap.
/// Lock-guarded peak ring buffer written from the audio thread and read from the
/// main thread. Lives outside the actor so `ingest` stays real-time safe.
final class PeakRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var ring: [Float]
    private var writeIndex = 0
    private var count = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.ring = [Float](repeating: 0, count: capacity)
    }

    func append(_ value: Float) {
        lock.lock()
        ring[writeIndex] = value
        writeIndex = (writeIndex + 1) % capacity
        count = min(count + 1, capacity)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        for i in ring.indices { ring[i] = 0 }
        writeIndex = 0
        count = 0
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if count < capacity {
            return Array(ring[0..<count])
        }
        return Array(ring[writeIndex..<capacity]) + Array(ring[0..<writeIndex])
    }
}

@MainActor
final class WaveformSampler: ObservableObject {
    /// Most recent peak magnitudes (0...1), oldest first, for the rolling meter.
    @Published private(set) var levels: [Float] = []
    /// Current input peak for a simple level meter.
    @Published private(set) var currentLevel: Float = 0

    private let buffer: PeakRingBuffer
    private var timer: Timer?

    init(windowColumns: Int = 240) {
        self.buffer = PeakRingBuffer(capacity: windowColumns)
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishSnapshot() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        buffer.reset()
        levels = []
        currentLevel = 0
    }

    /// Called on the audio thread. Computes a single peak for the buffer.
    nonisolated func ingest(_ pcm: AVAudioPCMBuffer) {
        guard let channel = pcm.floatChannelData?[0] else { return }
        let frames = vDSP_Length(pcm.frameLength)
        guard frames > 0 else { return }
        var peak: Float = 0
        vDSP_maxmgv(channel, 1, &peak, frames)
        buffer.append(peak)
    }

    private func publishSnapshot() {
        let snapshot = buffer.snapshot()
        levels = snapshot
        currentLevel = snapshot.last ?? 0
    }
}

/// Pre-computes a static min/max waveform for an audio file region (used to draw
/// clips on the timeline). Runs off the main thread; results are cached by caller.
enum WaveformAnalyzer {
    /// Returns `columns` peak magnitudes summarizing the given frame range of a file.
    static func peaks(for url: URL,
                      startFrame: AVAudioFramePosition,
                      frameCount: AVAudioFramePosition,
                      columns: Int) -> [Float] {
        guard columns > 0, frameCount > 0,
              let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let total = min(frameCount, file.length - startFrame)
        guard total > 0 else { return [] }

        let framesPerColumn = max(1, Int(total) / columns)
        let bufferCapacity = AVAudioFrameCount(framesPerColumn)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferCapacity) else { return [] }

        file.framePosition = startFrame
        var result: [Float] = []
        result.reserveCapacity(columns)

        for _ in 0..<columns {
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: bufferCapacity) }
            catch { break }
            guard buffer.frameLength > 0, let ch = buffer.floatChannelData?[0] else { break }
            var peak: Float = 0
            vDSP_maxmgv(ch, 1, &peak, vDSP_Length(buffer.frameLength))
            result.append(peak)
        }
        return result
    }
}
