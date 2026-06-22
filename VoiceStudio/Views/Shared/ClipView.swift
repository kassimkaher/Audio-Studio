import SwiftUI
import AVFoundation

/// A draggable, trimmable clip. Horizontal drag moves it in time; vertical drag
/// moves it between track lanes (Audition-style). Side handles trim non-
/// destructively. Tap selects; the ⓘ button opens the per-clip inspector.
struct ClipView: View {
    @ObservedObject var editor: ProjectEditorViewModel
    @EnvironmentObject private var playback: PlaybackService
    let clip: Clip
    let track: Track
    let source: AudioSource?
    let laneHeight: CGFloat
    let laneSpacing: CGFloat
    var onInspect: () -> Void

    @State private var dragKind: DragKind = .none
    @State private var translation: CGSize = .zero
    @State private var peaks: [Float] = []

    private enum DragKind { case none, move, left, right, fadeLeft, fadeRight, gain }
    private let handleWidth: CGFloat = 14

    private var isSelected: Bool { editor.selectedClipID == clip.id }
    private var baseWidth: CGFloat { editor.x(forFrame: clip.frameLength) }
    private var baseX: CGFloat { editor.x(forFrame: clip.timelineStartFrame) }
    private var sr: Double { editor.sampleRate }

    /// Raddah/crowd clips carry the warm amber identity (Live Majlis chain or name).
    private var isRaddah: Bool {
        clip.name.range(of: "raddah", options: .caseInsensitive) != nil
            || clip.name.contains("ردّة")
            || (clip.effectChain?.stages.contains { $0.stringParams?[ParamKeys.ir] == "LiveMajlis" } ?? false)
    }

    /// Live fade widths (in points), reflecting an in-progress drag.
    private var fadeInW: CGFloat {
        var sec = clip.fadeIn
        if dragKind == .fadeLeft { sec += Double(editor.frames(forWidth: translation.width)) / sr }
        return min(liveWidth, max(0, editor.x(forFrame: AVAudioFramePosition(max(0, sec) * sr))))
    }
    private var fadeOutW: CGFloat {
        var sec = clip.fadeOut
        if dragKind == .fadeRight { sec -= Double(editor.frames(forWidth: translation.width)) / sr }
        return min(liveWidth, max(0, editor.x(forFrame: AVAudioFramePosition(max(0, sec) * sr))))
    }

    /// The clip's gain reflecting an in-progress vertical drag (0…2).
    private var liveGain: Float {
        var g = clip.gain
        if dragKind == .gain { g -= Float(translation.height / max(1, laneHeight - 8)) * 2 }
        return max(0, min(g, 2))
    }
    /// Live y of the gain-envelope line (gain 0…2 → bottom…top).
    private var gainLineY: CGFloat {
        (1 - CGFloat(liveGain / 2)) * (laneHeight - 8) + 4
    }

    private var liveX: CGFloat {
        switch dragKind {
        case .move: return max(0, baseX + translation.width)
        case .left: return max(0, baseX + translation.width)
        default: return baseX
        }
    }
    private var liveWidth: CGFloat {
        switch dragKind {
        case .left: return max(handleWidth * 2, baseWidth - translation.width)
        case .right: return max(handleWidth * 2, baseWidth + translation.width)
        default: return baseWidth
        }
    }
    private var liveY: CGFloat { dragKind == .move ? translation.height : 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.white : color.opacity(0.6), lineWidth: isSelected ? 2 : 1))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if clip.effectChain != nil {
                        Image(systemName: "wand.and.stars").font(.system(size: 9)).foregroundStyle(color)
                    }
                    Text(clip.name).font(.system(size: 10, weight: .medium))
                        .lineLimit(1).foregroundStyle(Theme.textPrimary.opacity(0.9))
                }
                .padding(.leading, handleWidth + 2).padding(.top, 4)
                ClipWaveformView(peaks: peaks, color: color.opacity(0.9), gain: liveGain)
                    .padding(.horizontal, handleWidth).padding(.bottom, 6)
            }

            // Raddah/crowd chip.
            if isRaddah {
                Image(systemName: "person.2.wave.2.fill").font(.system(size: 9))
                    .foregroundStyle(.black.opacity(0.7))
                    .padding(3).background(Theme.accentWarm).clipShape(Capsule())
                    .offset(x: handleWidth + 2, y: laneHeight - 20)
            }

            // Non-destructive fade shading + corner handles.
            fadeOverlay
            fadeHandle(.fadeLeft).position(x: fadeInW, y: 8)
            fadeHandle(.fadeRight).position(x: liveWidth - fadeOutW, y: 8)

            // Gain-envelope line (drag vertically to ride the clip's level).
            Rectangle().fill(color)
                .frame(width: max(0, liveWidth - handleWidth * 2), height: 2)
                .overlay(Circle().fill(color).frame(width: 9, height: 9).offset(x: -(liveWidth/2) + handleWidth + 12))
                .position(x: liveWidth / 2, y: gainLineY)
                .contentShape(Rectangle().inset(by: -8))
                .gesture(gainGesture)

            handle(.left).frame(width: handleWidth)
            HStack { Spacer(); handle(.right).frame(width: handleWidth) }

            if isSelected {
                Button(action: onInspect) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11)).padding(5)
                        .background(.black.opacity(0.4)).clipShape(Circle())
                        .foregroundStyle(.white)
                }
                .offset(x: liveWidth - 30, y: 4)
                .accessibilityLabel("Edit clip")
            }
        }
        .frame(width: liveWidth, height: laneHeight)
        .offset(x: liveX, y: liveY)
        .zIndex(dragKind == .move ? 10 : 0)
        .contentShape(Rectangle())
        .gesture(moveGesture)
        .contextMenu {
            Button { editor.select(clip, in: track); onInspect() } label: { Label("Edit…", systemImage: "slider.horizontal.3") }
            Button { editor.duplicateClip(clip.id) } label: { Label("Duplicate (same track)", systemImage: "plus.square.on.square") }
            Button { editor.duplicateClipToNewTrack(clip.id) } label: { Label("Duplicate to New Track", systemImage: "rectangle.stack.badge.plus") }
            Button { _ = editor.splitClip(clip.id, atFrame: playback.currentFrame) } label: { Label("Split at Playhead", systemImage: "scissors") }
            Button { editor.setClipStart(clip.id, toFrame: playback.currentFrame) } label: { Label("Move to Playhead", systemImage: "arrow.right.to.line") }
            Divider()
            Button(role: .destructive) { editor.deleteClipAnywhere(clip.id) } label: { Label("Delete", systemImage: "trash") }
        }
        .task(id: clip.id) { await loadPeaks() }
    }

    private var color: Color {
        if isRaddah { return Theme.accentWarm }
        return track.kind == .vocal ? Theme.accent : Theme.accentWarm
    }

    private func handle(_ side: DragKind) -> some View {
        Rectangle().fill(color.opacity(isSelected ? 0.9 : 0.5))
            .overlay(Capsule().fill(.white.opacity(0.8)).frame(width: 3, height: 22))
            .gesture(trimGesture(side))
    }

    /// Smooth gradient wedges shading the faded-in / faded-out regions.
    private var fadeOverlay: some View {
        ZStack(alignment: .topLeading) {
            if fadeInW > 1 {
                Path { p in
                    p.move(to: .zero)
                    p.addLine(to: CGPoint(x: 0, y: laneHeight))
                    p.addLine(to: CGPoint(x: fadeInW, y: 0))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [.black.opacity(0.62), .clear],
                                     startPoint: .leading, endPoint: .trailing))
            }
            if fadeOutW > 1 {
                Path { p in
                    p.move(to: CGPoint(x: liveWidth, y: 0))
                    p.addLine(to: CGPoint(x: liveWidth, y: laneHeight))
                    p.addLine(to: CGPoint(x: liveWidth - fadeOutW, y: 0))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [.clear, .black.opacity(0.62)],
                                     startPoint: .leading, endPoint: .trailing))
            }
        }
        .allowsHitTesting(false)
    }

    private func fadeHandle(_ side: DragKind) -> some View {
        Triangle(pointingLeft: side == .fadeLeft)
            .fill(.white)
            .overlay(Triangle(pointingLeft: side == .fadeLeft).stroke(.black.opacity(0.45), lineWidth: 0.75))
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
            .contentShape(Rectangle().inset(by: -7))
            .gesture(fadeGesture(side))
            .help(side == .fadeLeft ? "Fade in" : "Fade out")
    }

    // MARK: Gestures

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragKind == .none { dragKind = .move; editor.select(clip, in: track) }
                if dragKind == .move { translation = value.translation }
            }
            .onEnded { value in
                guard dragKind == .move else { return }
                let deltaFrames = editor.frames(forWidth: value.translation.width)
                let newStart = max(0, clip.timelineStartFrame + deltaFrames)

                // Vertical move → target track based on lane row height.
                let rowH = laneHeight + laneSpacing
                let rowDelta = Int((value.translation.height / rowH).rounded())
                if rowDelta != 0,
                   let curIdx = editor.project.tracks.firstIndex(where: { $0.id == track.id }) {
                    let targetIdx = min(max(0, curIdx + rowDelta), editor.project.tracks.count - 1)
                    let targetID = editor.project.tracks[targetIdx].id
                    if targetID != track.id {
                        editor.moveClip(clip.id, toTrack: targetID, atFrame: newStart)
                        reset(); return
                    }
                }
                var updated = clip
                updated.timelineStartFrame = newStart
                editor.updateClip(updated, onTrack: track.id)
                reset()
            }
    }

    private func trimGesture(_ side: DragKind) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in dragKind = side; translation = value.translation }
            .onEnded { value in
                let delta = editor.frames(forWidth: value.translation.width)
                var updated = clip
                let maxOut = source?.frameCount ?? clip.sourceOutFrame
                if side == .left {
                    let newStart = max(0, min(clip.timelineStartFrame + delta, clip.timelineEndFrame - 1))
                    let applied = newStart - clip.timelineStartFrame
                    updated.timelineStartFrame = newStart
                    updated.sourceInFrame = max(0, min(clip.sourceInFrame + applied, clip.sourceOutFrame - 1))
                } else if side == .right {
                    updated.sourceOutFrame = max(clip.sourceInFrame + 1, min(clip.sourceOutFrame + delta, maxOut))
                }
                editor.updateClip(updated, onTrack: track.id)
                reset()
            }
    }

    private func fadeGesture(_ side: DragKind) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in dragKind = side; translation = value.translation }
            .onEnded { value in
                let deltaSec = Double(editor.frames(forWidth: value.translation.width)) / sr
                var u = clip
                let maxSec = clip.duration(sampleRate: sr)
                if side == .fadeLeft {
                    u.fadeIn = max(0, min(clip.fadeIn + deltaSec, maxSec))
                } else {
                    u.fadeOut = max(0, min(clip.fadeOut - deltaSec, maxSec))
                }
                editor.updateClip(u, onTrack: track.id)
                reset()
            }
    }

    private var gainGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                dragKind = .gain; translation = value.translation
                editor.setClipGainLive(clip.id, liveGain)   // heard instantly while dragging
            }
            .onEnded { value in
                let g = clip.gain - Float(value.translation.height / max(1, laneHeight - 8)) * 2
                var u = clip
                u.gain = max(0, min(g, 2))
                editor.updateClip(u, onTrack: track.id)     // persist
                editor.setClipGainLive(u.id, u.gain)
                reset()
            }
    }

    private func reset() { dragKind = .none; translation = .zero }

    private func loadPeaks() async {
        guard let source else { return }
        let url = source.url
        let inF = clip.sourceInFrame
        let len = clip.frameLength
        let cols = max(20, Int(baseWidth / 3))
        let result = await Task.detached(priority: .utility) {
            WaveformAnalyzer.peaks(for: url, startFrame: inF, frameCount: len, columns: cols)
        }.value
        await MainActor.run { peaks = result }
    }
}

/// A small right-angle triangle for the fade corner handles.
private struct Triangle: Shape {
    var pointingLeft: Bool
    func path(in r: CGRect) -> Path {
        Path { p in
            if pointingLeft {
                p.move(to: CGPoint(x: r.minX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            } else {
                p.move(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.minX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            }
            p.closeSubpath()
        }
    }
}
