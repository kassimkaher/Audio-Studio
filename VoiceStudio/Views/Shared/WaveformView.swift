import SwiftUI

/// Rolling waveform meter drawn with `Canvas` for efficiency. Expects peak
/// magnitudes in 0...1, oldest first.
struct WaveformView: View {
    var levels: [Float]
    var color: Color = Theme.accent
    var mirrored: Bool = true

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let midY = size.height / 2
            let count = levels.count
            let barWidth = max(1.5, size.width / CGFloat(count) * 0.7)
            let step = size.width / CGFloat(count)

            for (i, level) in levels.enumerated() {
                let x = CGFloat(i) * step + step / 2
                let h = max(2, CGFloat(min(level, 1)) * size.height * 0.9)
                let rect: CGRect
                if mirrored {
                    rect = CGRect(x: x - barWidth / 2, y: midY - h / 2, width: barWidth, height: h)
                } else {
                    rect = CGRect(x: x - barWidth / 2, y: size.height - h, width: barWidth, height: h)
                }
                let opacity = 0.35 + 0.65 * Double(i) / Double(max(1, count - 1))
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(color.opacity(opacity))
                )
            }
        }
        .drawingGroup()
    }
}

/// A simple static peak rendering for a clip's cached waveform.
struct ClipWaveformView: View {
    var peaks: [Float]
    var color: Color

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let midY = size.height / 2
            let step = size.width / CGFloat(peaks.count)
            for (i, p) in peaks.enumerated() {
                let x = CGFloat(i) * step
                let h = max(1, CGFloat(min(p, 1)) * size.height * 0.85)
                let rect = CGRect(x: x, y: midY - h / 2, width: max(0.8, step * 0.8), height: h)
                context.fill(Path(rect), with: .color(color))
            }
        }
    }
}
