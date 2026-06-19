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

    private enum DragKind { case none, move, left, right }
    private let handleWidth: CGFloat = 14

    private var isSelected: Bool { editor.selectedClipID == clip.id }
    private var baseWidth: CGFloat { editor.x(forFrame: clip.frameLength) }
    private var baseX: CGFloat { editor.x(forFrame: clip.timelineStartFrame) }

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
                ClipWaveformView(peaks: peaks, color: color.opacity(0.9))
                    .padding(.horizontal, handleWidth).padding(.bottom, 6)
            }

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
        .onTapGesture { editor.select(clip, in: track) }
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

    private var color: Color { track.kind == .vocal ? Theme.accent : Theme.accentWarm }

    private func handle(_ side: DragKind) -> some View {
        Rectangle().fill(color.opacity(isSelected ? 0.9 : 0.5))
            .overlay(Capsule().fill(.white.opacity(0.8)).frame(width: 3, height: 22))
            .gesture(trimGesture(side))
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
