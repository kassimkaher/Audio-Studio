import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// CapCut-style editor: a preview header with big timecode + play, a dark
/// ruler-based timeline with a prominent playhead, and a bottom tool bar.
struct ProjectEditorView: View {
    @StateObject private var editor: ProjectEditorViewModel
    @EnvironmentObject private var playback: PlaybackService

    @State private var showRecord = false
    @State private var showImporter = false
    @State private var showExport = false
    @State private var editingTrackID: UUID?
    @State private var inspectingClipID: UUID?
    @State private var showRename = false
    @State private var draftName = ""

    init(editor: ProjectEditorViewModel) {
        _editor = StateObject(wrappedValue: editor)
    }

    private let laneHeight: CGFloat = 56

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                previewPanel
                timelineSection
                bottomToolbar
            }
        }
        .navigationTitle(editor.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    draftName = editor.project.name; showRename = true
                } label: {
                    HStack(spacing: 4) {
                        Text(editor.project.name).font(.headline).foregroundStyle(Theme.textPrimary)
                        Image(systemName: "pencil").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(editor.project.totalFrames == 0)
            }
        }
        .alert("Rename Project", isPresented: $showRename) {
            TextField("Project name", text: $draftName)
            Button("Save") { editor.renameProject(draftName) }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showRecord) { RecordSessionView(editor: editor) }
        .sheet(isPresented: $showExport) { ExportView(project: editor.project) }
        .sheet(item: Binding(get: { editingTrackID.map(IDWrap.init) }, set: { editingTrackID = $0?.id })) { w in
            TrackEffectsSheet(editor: editor, trackID: w.id)
        }
        .sheet(item: Binding(get: { inspectingClipID.map(IDWrap.init) }, set: { inspectingClipID = $0?.id })) { w in
            ClipInspectorView(editor: editor, clipID: w.id)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio, .mp3, .wav, .aiff, .mpeg4Audio]) { result in
            if case .success(let url) = result {
                try? editor.importAudio(from: url, intoTrack: editor.selectedTrackID ?? editor.project.tracks.first?.id)
            }
        }
        .onDisappear { editor.stopPlayback(); editor.saveNow() }
    }

    // MARK: Preview header

    private var previewPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.06))
            VStack(spacing: 14) {
                Text(timecode)
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                HStack(spacing: 28) {
                    Button { editor.seek(toFrame: 0) } label: {
                        Image(systemName: "backward.end.fill").font(.system(size: 22))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .disabled(editor.project.totalFrames == 0)

                    Button { editor.togglePlay() } label: {
                        Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(Theme.accent)
                    }
                    .disabled(editor.project.totalFrames == 0)
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                    Button { editor.stopPlayback() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 20))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .disabled(editor.project.totalFrames == 0)
                }
            }
        }
        .frame(height: 200)
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private var timecode: String {
        let cur = Double(playback.currentFrame) / editor.sampleRate
        return "\(formatTime(cur)) / \(formatTime(editor.project.duration))"
    }

    // MARK: Timeline

    private var timelineSection: some View {
        Group {
            if editor.project.clipCount == 0 {
                emptyState
            } else {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 8) {
                            TimelineRuler(width: contentWidth, pixelsPerSecond: editor.pixelsPerSecond)
                                .frame(height: 18)
                                .contentShape(Rectangle())
                                .gesture(SpatialTapGesture().onEnded { v in
                                    editor.seek(toFrame: editor.frame(forX: v.location.x))
                                })
                            ForEach(editor.project.tracks) { track in lane(track) }
                        }
                        .padding(.vertical, 10)
                        playhead
                    }
                    .frame(width: contentWidth + 32, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.04))
    }

    private func lane(_ track: Track) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(editor.selectedTrackID == track.id ? Theme.accent.opacity(0.10) : Color(white: 0.10))
                    .frame(width: contentWidth, height: laneHeight)
                ForEach(track.clips) { clip in
                    ClipView(editor: editor, clip: clip, track: track,
                             source: editor.project.source(for: clip.sourceID),
                             laneHeight: laneHeight, laneSpacing: 8,
                             onInspect: { inspectingClipID = clip.id })
                }
                // Compact track label (visual only — must not intercept clip taps).
                HStack(spacing: 4) {
                    Image(systemName: track.kind == .vocal ? "mic.fill" : "music.note").font(.system(size: 9))
                    Text(track.name).font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.35)).clipShape(Capsule())
                .padding(4)
                .allowsHitTesting(false)
            }
        }
        .frame(height: laneHeight)
    }

    private var playhead: some View {
        Rectangle().fill(Theme.recordRed).frame(width: 2)
            .overlay(alignment: .top) {
                Circle().fill(Theme.recordRed).frame(width: 9, height: 9).offset(y: -3)
            }
            .offset(x: editor.x(forFrame: playback.currentFrame))
            .allowsHitTesting(false)
    }

    private var contentWidth: CGFloat { max(700, editor.x(forFrame: editor.project.totalFrames) + 240) }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.circle").font(.system(size: 48)).foregroundStyle(.white.opacity(0.4))
            Text("Tap Record or Import to add audio")
                .font(.subheadline).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bottom tool bar (CapCut-style)

    private var bottomToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tool("Record", "mic.fill", tint: Theme.recordRed) { showRecord = true }
                tool("Import", "plus.square") { showImporter = true }
                tool("Add Track", "rectangle.stack.badge.plus") { editor.addTrack() }
                Divider().frame(height: 36).overlay(Color.white.opacity(0.12))
                tool("Split", "scissors", enabled: editor.hasSelection) {
                    _ = editor.splitSelectedClip(atFrame: playback.currentFrame)
                }
                tool("Effects", "wand.and.stars", enabled: editor.hasSelection) {
                    if let c = editor.selectedClipID { inspectingClipID = c }
                }
                tool("Track FX", "slider.horizontal.3", enabled: !editor.project.tracks.isEmpty) {
                    editingTrackID = editor.selectedTrackID ?? editor.project.tracks.first?.id
                }
                tool("Delete", "trash", tint: Theme.recordRed, enabled: editor.hasSelection) {
                    if let c = editor.selectedClipID, let t = editor.selectedTrackID { editor.deleteClip(c, fromTrack: t) }
                }
                tool("Export", "square.and.arrow.up", enabled: editor.project.totalFrames > 0) { showExport = true }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(Color(white: 0.08))
    }

    private func tool(_ label: String, _ symbol: String, tint: Color = .white,
                      enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 19))
                    .frame(width: 52, height: 40)
                    .background(Color(white: 0.15)).clipShape(RoundedRectangle(cornerRadius: 10))
                Text(label).font(.system(size: 10))
            }
            .foregroundStyle(enabled ? tint : .white.opacity(0.3))
        }
        .buttonStyle(.plain).disabled(!enabled)
    }
}

/// Identifiable wrapper so a `UUID?` can drive `.sheet(item:)`.
struct IDWrap: Identifiable { let id: UUID }

/// CapCut-style time ruler with second ticks and labels.
struct TimelineRuler: View {
    let width: CGFloat
    let pixelsPerSecond: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let seconds = Int(width / pixelsPerSecond) + 1
            let labelEvery = pixelsPerSecond < 40 ? 5 : (pixelsPerSecond < 90 ? 2 : 1)
            for s in 0...max(1, seconds) {
                let x = CGFloat(s) * pixelsPerSecond
                guard x <= width else { break }
                let major = s % labelEvery == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - (major ? 10 : 5)))
                path.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(path, with: .color(.white.opacity(major ? 0.4 : 0.18)), lineWidth: 1)
                if major {
                    let text = Text("\(s)s").font(.system(size: 8)).foregroundColor(.white.opacity(0.45))
                    ctx.draw(text, at: CGPoint(x: x + 2, y: 4), anchor: .leading)
                }
            }
        }
    }
}
