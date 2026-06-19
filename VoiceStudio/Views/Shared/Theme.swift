import SwiftUI

/// Centralized colors, gradients and small reusable view styles.
enum Theme {
    static let accent = Color(red: 0.38, green: 0.72, blue: 0.95)
    static let accentWarm = Color(red: 0.95, green: 0.78, blue: 0.42)
    static let recordRed = Color(red: 0.92, green: 0.28, blue: 0.32)

    static let background = Color(red: 0.06, green: 0.07, blue: 0.10)
    static let surface = Color(red: 0.11, green: 0.12, blue: 0.16)
    static let surfaceElevated = Color(red: 0.15, green: 0.16, blue: 0.21)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.6)

    static var screenBackground: LinearGradient {
        LinearGradient(colors: [background, Color(red: 0.04, green: 0.05, blue: 0.08)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// A rounded card container used across screens.
struct Card<Content: View>: View {
    let content: Content
    var padding: CGFloat = 16
    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    var body: some View {
        content
            .padding(padding)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    /// Inline navigation title on iOS; a no-op on macOS (which lacks the modifier).
    @ViewBuilder func inlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .tracking(1.2)
            self
        }
    }
}

/// Formats a time interval as m:ss.t for transport displays.
func formatTime(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let minutes = Int(t) / 60
    let seconds = Int(t) % 60
    return String(format: "%d:%02d", minutes, seconds)
}
