import Foundation
import AVFoundation

/// An immutable reference to a recorded/imported audio file on disk.
///
/// Sources are never mutated by editing — clips reference a source by `id` and
/// carry their own in/out trim points. This is the backbone of non-destructive
/// editing: the underlying WAV is written once and read many times.
struct AudioSource: Identifiable, Codable, Hashable {
    let id: UUID
    /// File name relative to the app's recordings directory (not an absolute URL,
    /// so projects remain portable across app container path changes).
    let fileName: String
    let sampleRate: Double
    let frameCount: AVAudioFramePosition
    let createdAt: Date

    init(id: UUID = UUID(),
         fileName: String,
         sampleRate: Double,
         frameCount: AVAudioFramePosition,
         createdAt: Date = Date()) {
        self.id = id
        self.fileName = fileName
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.createdAt = createdAt
    }

    /// Absolute URL resolved against the current recordings directory.
    var url: URL { AppPaths.recordingsDirectory.appendingPathComponent(fileName) }

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }
}

/// Centralized on-disk locations.
enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var recordingsDirectory: URL {
        let dir = documents.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var exportsDirectory: URL {
        let dir = documents.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var projectsDirectory: URL {
        let dir = documents.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
