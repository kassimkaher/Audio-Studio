import Foundation
import Combine

/// A user-saved effect "Mode" — a named effect chain that can be applied to any
/// clip, track, or new recording.
struct UserPreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var chain: EffectChainSpec

    init(id: UUID = UUID(), name: String, chain: EffectChainSpec) {
        self.id = id
        self.name = name
        self.chain = chain
    }
}

/// Persists user Modes to disk and publishes them for the preset picker.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [UserPreset] = []

    private var url: URL { AppPaths.documents.appendingPathComponent("modes.json") }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([UserPreset].self, from: data) else { return }
        presets = list
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) { try? data.write(to: url, options: .atomic) }
    }

    @discardableResult
    func add(name: String, chain: EffectChainSpec) -> UserPreset {
        let preset = UserPreset(name: name.isEmpty ? "My Mode" : name, chain: chain)
        presets.append(preset)
        persist()
        return preset
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }
}
