import SwiftUI

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        ProjectLibraryView()
            .tint(Theme.accent)
    }
}
