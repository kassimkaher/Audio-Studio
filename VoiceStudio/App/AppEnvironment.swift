import Foundation
import Combine

/// Dependency-injection container for the long-lived services. Views/view-models
/// never construct audio engines directly — they receive these via the SwiftUI
/// environment. The open project lives in `ProjectEditorViewModel`, not here.
@MainActor
final class AppEnvironment: ObservableObject {
    let sessionManager: AudioSessionManager
    let engineController: AudioEngineController
    let recordingService: RecordingService
    let playbackService: PlaybackService
    let mixdownRenderer: MixdownRenderer
    let projectStore: ProjectStore
    let presetStore: PresetStore
    let irLoader: IRLoader

    /// Set by UI tests (UITEST_RESET) to start from a clean library.
    let resetForTesting: Bool

    init() {
        let session = AudioSessionManager()
        let engine = AudioEngineController(sessionManager: session)
        self.sessionManager = session
        self.engineController = engine
        self.recordingService = RecordingService(engineController: engine, sessionManager: session)
        self.playbackService = PlaybackService(sessionManager: session)
        self.mixdownRenderer = MixdownRenderer()
        self.projectStore = ProjectStore()
        self.presetStore = PresetStore()
        self.irLoader = IRLoader()
        self.playbackService.recordEngine = engine   // release record engine before playback
        ConvolutionUnitProvider.shared.warmUp()       // pre-instantiate convolution AUs off the event loop
        self.resetForTesting = ProcessInfo.processInfo.arguments.contains("UITEST_RESET")
    }
}
