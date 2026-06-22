#if os(macOS)
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

struct MacEditorView: View {
    @ObservedObject var editor: ProjectEditorViewModel
    @StateObject private var captureVM: RecordSessionViewModel
    @EnvironmentObject private var playback: PlaybackService
    @EnvironmentObject private var session: AudioSessionManager

    init(editor: ProjectEditorViewModel) {
        self.editor = editor
        _captureVM = StateObject(wrappedValue: RecordSessionViewModel(env: editor.env))
    }

    @State private var showRecord = false
    @State private var showExport = false
    @State private var showImporter = false
    @State private var showRename = false
    @State private var draftName = ""
    @State private var spaceMonitor: Any?
    @State private var scrollX: CGFloat = 0     // current horizontal scroll offset of the timeline
    @State private var zoomAnchor: CGFloat?     // pixelsPerSecond captured at pinch start

    private let laneHeight: CGFloat = 84
    private let headerWidth: CGFloat = 170

    var body: some View {
        boardContent
            .background(Theme.background)
            .toolbar { toolbarContent }
            .toolbarBackground(Theme.background, for: .windowToolbar)
            .toolbarColorScheme(.dark, for: .windowToolbar)
            .animation(.easeInOut(duration: 0.2), value: showRecord)
            .modifier(BoardSheets(editor: editor, showExport: $showExport, showImporter: $showImporter,
                                  showRename: $showRename, draftName: $draftName))
            .modifier(BoardCommands(editor: editor, showRecord: $showRecord,
                                    showImporter: $showImporter, showExport: $showExport,
                                    onDelete: deleteSelected))
            .onAppear {
                session.prepareForInputSelection(); installSpaceMonitor()
                if editor.selectedTrackID == nil && editor.selectedClipID == nil {
                    editor.selectedTrackID = editor.project.tracks.first?.id
                }
            }
            .onDisappear { removeSpaceMonitor(); editor.stopPlayback(); editor.saveNow() }
    }

    private var boardContent: some View {
        VStack(spacing: 0) {
            StudioTopBar(editor: editor, onRecord: { showRecord = true }, onExport: { showExport = true })
            if showRecord {
                MacCaptureBar(editor: editor, vm: captureVM, onClose: { showRecord = false })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    timeline
                    Divider().overlay(Theme.hairline)
                    MacInspectorView(editor: editor, audience: captureVM)
                        .frame(width: min(max(geo.size.width * 0.32, 300), 460))
                }
            }
        }
    }

    // Spacebar = play/pause everywhere (except while typing or in a sheet). A
    // window key monitor is used so a focused button can't swallow the press.
    private func installSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49 else { return event }          // 49 = space
            if showRecord || showExport || showRename { return event } // let sheets/alerts handle it
            let responder = NSApp.keyWindow?.firstResponder
            if responder is NSText || (responder?.isKind(of: NSTextView.self) ?? false) { return event }
            editor.togglePlay()
            return nil   // consume so the focused control doesn't also act
        }
    }

    private func removeSpaceMonitor() {
        if let m = spaceMonitor { NSEvent.removeMonitor(m); spaceMonitor = nil }
    }

    // MARK: Toolbar (native window toolbar — auto-handles overflow, no clipping)

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // Transport, I/O and Export now live in the StudioTopBar (Zone 1); the
        // window toolbar keeps the editing tools.
        ToolbarItemGroup(placement: .principal) {
            Button { editor.addTrack() } label: { Label("Add Track", systemImage: "plus.rectangle.on.rectangle") }
                .help("Add Track")
            Button { draftName = editor.project.name; showRename = true } label: { Label("Rename", systemImage: "pencil") }
                .help("Rename Project")
            Button { showImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .help("Import Audio")
            Button { editor.splitSelectedClip(atFrame: playback.currentFrame) } label: { Image(systemName: "scissors") }
                .help("Split at Playhead").disabled(!editor.hasSelection)
            Button { deleteSelected() } label: { Image(systemName: "trash") }
                .help("Delete Clip").disabled(!editor.hasSelection)
            Slider(value: $editor.pixelsPerSecond, in: 20...200) { Text("Zoom") }
                .frame(width: 90).help("Zoom")
        }
    }

    // MARK: Timeline

    private let rulerHeight: CGFloat = 24
    private var playheadX: CGFloat { editor.x(forFrame: playback.currentFrame) }
    private var contentWidth: CGFloat { max(800, editor.x(forFrame: editor.project.totalFrames) + 300) }

    private var timeline: some View {
        GeometryReader { _ in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: rulerHeight)             // align headers under the ruler
                        VStack(spacing: 10) {
                            ForEach(editor.project.tracks) { track in
                                TrackHeaderView(editor: editor, track: track,
                                                onEditEffects: { editor.selectedTrackID = track.id; editor.selectedClipID = nil },
                                                onDelete: { editor.removeTrack(track.id) })
                                    .frame(height: laneHeight)
                            }
                        }.padding(.vertical, 8)
                    }
                    .frame(width: headerWidth).background(Theme.surface)

                    VStack(spacing: 0) {
                        rulerBar
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 10) {
                                ForEach(editor.project.tracks) { track in lane(track) }
                            }
                            .padding(.vertical, 8)
                            // Playhead line + a zero-size anchor used for auto-scroll.
                            Rectangle().fill(Theme.recordRed).frame(width: 2)
                                .offset(x: playheadX).allowsHitTesting(false)
                                .neonGlow(Theme.recordRed, radius: 4)
                            Color.clear.frame(width: 1, height: 1)
                                .position(x: playheadX, y: 1).id("playhead")
                        }
                        .frame(width: contentWidth, alignment: .leading)
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ScrollOffsetKey.self,
                                           value: g.frame(in: .named("timeline")).minX)
                })
            }
            .coordinateSpace(name: "timeline")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPreferenceChange(ScrollOffsetKey.self) { scrollX = -$0 }
            // Two-finger pinch zooms the timeline horizontally (Audition-style).
            .gesture(
                MagnificationGesture()
                    .onChanged { scale in
                        let base = zoomAnchor ?? editor.pixelsPerSecond
                        if zoomAnchor == nil { zoomAnchor = base }
                        editor.pixelsPerSecond = min(max(base * scale,
                            ProjectEditorViewModel.minPixelsPerSecond),
                            ProjectEditorViewModel.maxPixelsPerSecond)
                    }
                    .onEnded { _ in zoomAnchor = nil }
            )
            // Auto-scroll (playhead follow) disabled per user preference — the
            // timeline stays put while the playhead moves; scroll manually.
        }
    }

    /// Time ruler: tick marks + tap/drag to scrub & seek the playhead.
    private var rulerBar: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.surface)
            Canvas { ctx, size in
                let sr = editor.sampleRate
                let secWidth = editor.x(forFrame: AVAudioFramePosition(sr))
                guard secWidth > 4 else { return }
                var s = 0
                var x: CGFloat = 0
                while x < size.width {
                    let tall = s % 5 == 0
                    ctx.stroke(Path { p in
                        p.move(to: CGPoint(x: x, y: tall ? 6 : 12)); p.addLine(to: CGPoint(x: x, y: size.height))
                    }, with: .color(Theme.textSecondary.opacity(tall ? 0.5 : 0.25)), lineWidth: 1)
                    if tall {
                        ctx.draw(Text("\(s)").font(.system(size: 8, design: .monospaced))
                            .foregroundColor(Theme.textSecondary), at: CGPoint(x: x + 8, y: 6))
                    }
                    s += 1; x += secWidth
                }
            }
            // Playhead head marker on the ruler.
            Path { p in
                p.move(to: CGPoint(x: playheadX - 5, y: 0)); p.addLine(to: CGPoint(x: playheadX + 5, y: 0))
                p.addLine(to: CGPoint(x: playheadX, y: 8)); p.closeSubpath()
            }.fill(Theme.recordRed)
        }
        .frame(width: contentWidth, height: rulerHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            editor.seek(toFrame: editor.frames(forWidth: max(0, v.location.x)))
        })
    }

    private func lane(_ track: Track) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(editor.selectedTrackID == track.id ? Theme.accent.opacity(0.08) : Theme.surface.opacity(0.5))
                .frame(height: laneHeight)
            ForEach(track.clips) { clip in
                ClipView(editor: editor, clip: clip, track: track,
                         source: editor.project.source(for: clip.sourceID),
                         laneHeight: laneHeight, laneSpacing: 10, onInspect: { editor.select(clip, in: track) })
            }
        }
        // Span the full timeline width so clips offset to the right stay INSIDE
        // the lane's bounds and remain tappable (offset views outside the parent
        // frame don't receive taps).
        .frame(width: contentWidth, height: laneHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { editor.selectedTrackID = track.id; editor.selectedClipID = nil }
        .contextMenu {
            Button { editor.selectedTrackID = track.id; showImporter = true } label: { Label("Import Audio…", systemImage: "square.and.arrow.down") }
            Button { editor.addTrack() } label: { Label("Add Track", systemImage: "plus.rectangle.on.rectangle") }
            Button { editor.duplicateTrack(track.id) } label: { Label("Duplicate Track", systemImage: "plus.square.on.square") }
            if editor.canPaste {
                Button { editor.selectedTrackID = track.id; editor.pasteClipboard() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            }
            Divider()
            Button(role: .destructive) { editor.removeTrack(track.id) } label: { Label("Delete Track", systemImage: "trash") }
        }
    }

    private func deleteSelected() {
        if let c = editor.selectedClipID, let t = editor.selectedTrackID { editor.deleteClip(c, fromTrack: t) }
    }
}

/// Reports the timeline content's horizontal offset for auto-scroll decisions.
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Sheets / alerts / importer, split out so the body type-checks quickly.
private struct BoardSheets: ViewModifier {
    @ObservedObject var editor: ProjectEditorViewModel
    @Binding var showExport: Bool
    @Binding var showImporter: Bool
    @Binding var showRename: Bool
    @Binding var draftName: String

    func body(content: Content) -> some View {
        content
            .alert("Rename Project", isPresented: $showRename) {
                TextField("Project name", text: $draftName)
                Button("Save") { editor.renameProject(draftName) }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showExport) { ExportView(project: editor.project).frame(width: 460, height: 560) }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.audio, .mp3, .wav, .aiff, .mpeg4Audio]) { result in
                if case .success(let url) = result {
                    try? editor.importAudio(from: url, intoTrack: editor.selectedTrackID ?? editor.project.tracks.first?.id)
                }
            }
    }
}

/// Menu-command notification handlers, split out for the same reason.
private struct BoardCommands: ViewModifier {
    @ObservedObject var editor: ProjectEditorViewModel
    @Binding var showRecord: Bool
    @Binding var showImporter: Bool
    @Binding var showExport: Bool
    var onDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .vsRecord)) { _ in showRecord = true }
            .onReceive(NotificationCenter.default.publisher(for: .vsPlayStop)) { _ in editor.togglePlay() }
            .onReceive(NotificationCenter.default.publisher(for: .vsAddTrack)) { _ in editor.addTrack() }
            .onReceive(NotificationCenter.default.publisher(for: .vsImport)) { _ in showImporter = true }
            .onReceive(NotificationCenter.default.publisher(for: .vsExport)) { _ in showExport = true }
            .onReceive(NotificationCenter.default.publisher(for: .vsDeleteClip)) { _ in onDelete() }
            .onReceive(NotificationCenter.default.publisher(for: .vsCopy)) { _ in editor.copySelection() }
            .onReceive(NotificationCenter.default.publisher(for: .vsPaste)) { _ in editor.pasteClipboard() }
            .onReceive(NotificationCenter.default.publisher(for: .vsDuplicate)) { _ in editor.duplicateSelection() }
            .onReceive(NotificationCenter.default.publisher(for: .vsUndo)) { _ in editor.undo() }
            .onReceive(NotificationCenter.default.publisher(for: .vsRedo)) { _ in editor.redo() }
    }
}
#endif
