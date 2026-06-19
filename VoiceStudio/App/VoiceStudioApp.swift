import SwiftUI

@main
struct VoiceStudioApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(environment)
                .environmentObject(environment.recordingService)
                .environmentObject(environment.playbackService)
                .environmentObject(environment.mixdownRenderer)
                .environmentObject(environment.sessionManager)
                .environmentObject(environment.engineController)
                .environmentObject(environment.presetStore)
                .environmentObject(environment.irLoader)
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .commands { VoiceStudioCommands() }
        #endif
    }

    @ViewBuilder private var rootView: some View {
        #if os(macOS)
        MacRootView()
        #else
        RootView()
        #endif
    }
}
