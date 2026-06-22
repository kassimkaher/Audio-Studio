import SwiftUI

/// Centralized colors, gradients and small reusable view styles.
enum Theme {
    // Exact Stitch "Sacred Audio DAW" palette.
    static let accent = Color(red: 0.0, green: 0.961, blue: 0.831)         // #00F5D4 sonic teal
    static let accentBright = Color(red: 0.149, green: 0.996, blue: 0.863) // #26FEDC
    static let accentWarm = Color(red: 0.984, green: 0.706, blue: 0.0)     // #FBB400 sacred amber
    static let recordRed = Color(red: 1.0, green: 0.27, blue: 0.23)        // bright record red

    static let background = Color(red: 0.047, green: 0.055, blue: 0.067)   // #0C0E11 obsidian chrome
    static let surface = Color(red: 0.067, green: 0.075, blue: 0.086)      // #111316 panels/cards
    static let surfaceElevated = Color(red: 0.094, green: 0.106, blue: 0.122) // #181B1F rows
    static let hairline = Color(red: 0.20, green: 0.208, blue: 0.224)      // #333538 1px borders

    static let textPrimary = Color(red: 0.886, green: 0.886, blue: 0.902)  // #E2E2E6
    static let textSecondary = Color(red: 0.514, green: 0.580, blue: 0.561) // #83948F

    static var screenBackground: LinearGradient {
        LinearGradient(colors: [background, Color(red: 0.027, green: 0.035, blue: 0.043)],
                       startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    /// Neon glow used on active waveforms, the timecode, and accent chrome —
    /// matches the Stitch `drop-shadow-[0_0_8px_rgba(0,245,212,0.4)]` treatment.
    func neonGlow(_ color: Color = Theme.accent, radius: CGFloat = 6) -> some View {
        shadow(color: color.opacity(0.45), radius: radius, x: 0, y: 0)
    }

    /// Glowing sonic-teal treatment for the transport timecode.
    func tealGlow() -> some View {
        foregroundStyle(Theme.accent)
            .shadow(color: Theme.accent.opacity(0.55), radius: 8, x: 0, y: 0)
            .shadow(color: Theme.accent.opacity(0.35), radius: 2, x: 0, y: 0)
    }
}

/// A rounded card container used across screens: deep-gray surface, 12pt radius,
/// 1px hairline stroke. Optional accent glow (e.g. gold for the Audience card).
struct Card<Content: View>: View {
    let content: Content
    var padding: CGFloat = 16
    var glow: Color? = nil
    init(padding: CGFloat = 16, glow: Color? = nil, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.glow = glow
        self.content = content()
    }
    var body: some View {
        content
            .padding(padding)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(glow ?? Theme.hairline, lineWidth: 1)
            )
            .shadow(color: (glow ?? .black).opacity(glow == nil ? 0.3 : 0.45), radius: glow == nil ? 6 : 12, y: 2)
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

/// Precise DAW timecode `M:SS.mmm` for the studio transport display.
func formatTimecode(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "0:00.000" }
    let minutes = Int(t) / 60
    let seconds = Int(t) % 60
    let millis = Int((t - floor(t)) * 1000)
    return String(format: "%d:%02d.%03d", minutes, seconds, millis)
}
