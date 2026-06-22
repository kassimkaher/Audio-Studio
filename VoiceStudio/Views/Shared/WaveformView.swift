import SwiftUI

/// Rolling waveform meter drawn with `Canvas`. Peak magnitudes in 0...1, oldest
/// first. Bars are mirrored around the centre for a dual-channel look and carry a
/// subtle neon glow so the active signal reads as "lit".
struct WaveformView: View {
    var levels: [Float]
    var color: Color = Theme.accent
    var mirrored: Bool = true

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let midY = size.height / 2
            let count = levels.count
            let step = size.width / CGFloat(count)
            let barWidth = max(1.5, step * 0.66)

            for (i, level) in levels.enumerated() {
                let x = CGFloat(i) * step + step / 2
                let h = max(2, CGFloat(min(level, 1)) * size.height * 0.92)
                let rect: CGRect = mirrored
                    ? CGRect(x: x - barWidth / 2, y: midY - h / 2, width: barWidth, height: h)
                    : CGRect(x: x - barWidth / 2, y: size.height - h, width: barWidth, height: h)
                // Newer samples brighter → a "scrolling" energy gradient.
                let opacity = 0.4 + 0.6 * Double(i) / Double(max(1, count - 1))
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(color.opacity(opacity)))
            }
        }
        .drawingGroup()                       // anti-aliased, GPU-composited
        .neonGlow(color, radius: 6)
    }
}

/// High-density, anti-aliased static peak rendering for a clip's cached waveform,
/// mirrored top/bottom for a dual-channel feel with a faint glow.
struct ClipWaveformView: View {
    var peaks: [Float]
    var color: Color
    /// Clip gain (0…2) — scales the drawn peak height so the waveform reflects
    /// the gain-envelope ride (taller when boosted, flatter when attenuated).
    var gain: Float = 1

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let midY = size.height / 2
            let n = peaks.count
            let step = size.width / CGFloat(n)
            let g = CGFloat(min(max(gain, 0), 2))
            // Build a single mirrored outline path → crisp, filled silhouette.
            var top = Path()
            top.move(to: CGPoint(x: 0, y: midY))
            for (i, p) in peaks.enumerated() {
                let x = CGFloat(i) * step
                let h = min(midY, CGFloat(min(max(p, 0), 1)) * size.height * 0.46 * g)
                top.addLine(to: CGPoint(x: x, y: midY - h))
            }
            for (i, p) in peaks.enumerated().reversed() {
                let x = CGFloat(i) * step
                let h = min(midY, CGFloat(min(max(p, 0), 1)) * size.height * 0.46 * g)
                top.addLine(to: CGPoint(x: x, y: midY + h))
            }
            top.closeSubpath()
            context.fill(top, with: .linearGradient(
                Gradient(colors: [color.opacity(0.95), color.opacity(0.55)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            // Centre line for definition.
            context.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: size.width, y: midY))
            }, with: .color(color.opacity(0.5)), lineWidth: 0.5)
        }
        .drawingGroup()
        .neonGlow(color, radius: 4)
    }
}
