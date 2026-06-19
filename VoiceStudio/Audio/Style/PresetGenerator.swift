import Foundation

/// Reference Style Transfer (architecture). A `PresetGenerator` analyzes a
/// reference recording and produces a `VoiceProfile`. v1 ships a stub; a real
/// FFT spectral-analysis implementation can be injected later without changing
/// the UI, storage, or audio engine that already consume `VoiceProfile`.
protocol PresetGenerator {
    func generate(from referenceURL: URL) async throws -> VoiceProfile
}

/// Placeholder generator: returns a neutral profile regardless of input. Lets the
/// full pipeline (file → VoiceProfile → EffectChainSpec → saved Mode) be wired
/// and tested now, ahead of the real spectral-analysis engine.
struct StubPresetGenerator: PresetGenerator {
    func generate(from referenceURL: URL) async throws -> VoiceProfile {
        // Real implementation (future): window the reference, FFT each frame,
        // average the magnitude spectrum → EQ curve; estimate decay/space → IR id
        // + wet mix. For now, a sensible neutral starting point.
        VoiceProfile.neutral
    }
}
