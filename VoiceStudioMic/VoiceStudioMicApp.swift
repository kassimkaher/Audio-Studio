import SwiftUI

@main
struct VoiceStudioMicApp: App {
    var body: some Scene {
        WindowGroup {
            MicContentView().preferredColorScheme(.dark)
        }
    }
}
