import Foundation

/// Simple JSON-on-disk persistence for projects. Kept intentionally small;
/// SwiftData could replace this later without touching the model layer.
final class ProjectStore {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var lastOpenedURL: URL {
        AppPaths.projectsDirectory.appendingPathComponent("last.json")
    }

    func url(for project: Project) -> URL {
        AppPaths.projectsDirectory.appendingPathComponent("\(project.id.uuidString).json")
    }

    func save(_ project: Project) throws {
        var copy = project
        copy.updatedAt = Date()
        let data = try encoder.encode(copy)
        try data.write(to: url(for: copy), options: .atomic)
        try? data.write(to: lastOpenedURL, options: .atomic)
    }

    func load(id: UUID) -> Project? {
        let url = AppPaths.projectsDirectory.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Project.self, from: data)
    }

    func loadLast() -> Project? {
        guard let data = try? Data(contentsOf: lastOpenedURL) else { return nil }
        return try? decoder.decode(Project.self, from: data)
    }

    /// Deletes a project's JSON and all of its source audio files from disk.
    func delete(_ project: Project) {
        let fm = FileManager.default
        for source in project.sources {
            try? fm.removeItem(at: source.url)
        }
        try? fm.removeItem(at: url(for: project))
        // Clear the "last opened" pointer if it referenced this project.
        if let data = try? Data(contentsOf: lastOpenedURL),
           let last = try? decoder.decode(Project.self, from: data),
           last.id == project.id {
            try? fm.removeItem(at: lastOpenedURL)
        }
    }

    func allProjects() -> [Project] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.projectsDirectory,
            includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "last.json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(Project.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
