import Foundation

/// Orchestrates Reference Style Transfer: analyze a reference file into a
/// `VoiceProfile`, convert it to an effect chain, and save it as a reusable Mode.
/// The generator is injectable, so the real FFT analysis swaps in later with no
/// changes here or downstream.
@MainActor
final class StyleCaptureService {
    private let generator: PresetGenerator
    private let presetStore: PresetStore

    init(generator: PresetGenerator = StubPresetGenerator(), presetStore: PresetStore) {
        self.generator = generator
        self.presetStore = presetStore
    }

    /// Analyzes `referenceURL` and saves the captured style as a Mode; returns it.
    @discardableResult
    func captureMode(from referenceURL: URL, named name: String) async throws -> UserPreset {
        let profile = try await generator.generate(from: referenceURL)
        return presetStore.add(name: name, chain: profile.makeChain())
    }
}
