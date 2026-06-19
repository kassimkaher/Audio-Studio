#if os(macOS)
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

struct MacEditorView: View {
    @ObservedObject var editor: ProjectEditorViewModel
    @EnvironmentObject private var playback: PlaybackService
    @EnvironmentObject private var session: AudioSessionManager

    @State private var showRecord = false
    @State private var showExport = false
    @State private var showImporter = false
    @State private var showRename = false
    @State private var draftName = ""
    @State private var spaceMonitor: Any?

    private let laneHeight: CGFloat = 84
    private let headerWidth: CGFloat = 170

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                timeline
                Divider().overlay(Color.white.opacity(0.08))
                // Inspector width adapts to the window so all controls stay legible.
                MacInspectorView(editor: editor)
                    .frame(width: min(max(geo.size.width * 0.32, 300), 460))
            }
        }
        .background(Theme.background)
        .navigationTitle(editor.project.name)
        .navigationSubtitle(formatTime(Double(playback.currentFrame) / editor.sampleRate))
        .toolbar { toolbarContent }
        .alert("Rename Project", isPresented: $showRename) {
            TextField("Project name", text: $draftName)
            Button("Save") { editor.renameProject(draftName) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showRecord) { MacRecordPanel(editor: editor) }
        .sheet(isPresented: $showExport) { ExportView(project: editor.project).frame(width: 460, height: 560) }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio, .mp3, .wav, .aiff, .mpeg4Audio]) { result in
            if case .success(let url) = result {
                try? editor.importAudio(from: url, intoTrack: editor.selectedTrackID ?? editor.project.tracks.first?.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vsRecord)) { _ in showRecord = true }
        .onReceive(NotificationCenter.default.publisher(for: .vsPlayStop)) { _ in editor.togglePlay() }
        .onReceive(NotificationCenter.default.publisher(for: .vsAddTrack)) { _ in editor.addTrack() }
        .onReceive(NotificationCenter.default.publisher(for: .vsImport)) { _ in showImporter = true }
        .onReceive(NotificationCenter.default.publisher(for: .vsExport)) { _ in showExport = true }
        .onReceive(NotificationCenter.default.publisher(for: .vsDeleteClip)) { _ in deleteSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .vsCopy)) { _ in editor.copySelection() }
        .onReceive(NotificationCenter.default.publisher(for: .vsPaste)) { _ in editor.pasteClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: .vsDuplicate)) { _ in editor.duplicateSelection() }
        .onAppear { session.prepareForInputSelection(); installSpaceMonitor() }
        .onDisappear { removeSpaceMonitor(); editor.stopPlayback(); editor.saveNow() }
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
        ToolbarItemGroup(placement: .navigation) {
            Button { editor.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .help("Play / Stop")
            Button { editor.stopPlayback() } label: { Image(systemName: "stop.fill") }
                .help("Stop")
        }
        ToolbarItemGroup(placement: .principal) {
            Button { showRecord = true } label: { Label("Record", systemImage: "mic.fill") }
                .help("Record")
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
        }
        ToolbarItemGroup(placement: .primaryAction) {
            DevicePicker(title: "In", systemImage: "mic", options: session.availableInputs,
                         selected: session.selectedInputUID) { session.selectInput(uid: $0) }
                .help("Input device")
            DevicePicker(title: "Out", systemImage: "hifispeaker", options: session.availableOutputs,
                         selected: session.selectedOutputUID) { session.selectOutput(uid: $0) }
                .help("Output device")
            Slider(value: $editor.pixelsPerSecond, in: 20...200) { Text("Zoom") }
                .frame(width: 90).help("Zoom")
            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .help("Export Mixdown")
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 10) {
                    ForEach(editor.project.tracks) { track in
                        TrackHeaderView(editor: editor, track: track,
                                        onEditEffects: { editor.selectedTrackID = track.id; editor.selectedClipID = nil },
                                        onDelete: { editor.removeTrack(track.id) })
                            .frame(height: laneHeight)
                    }
                }
                .padding(.vertical, 8).frame(width: headerWidth).background(Theme.surface)

                ZStack(alignment: .topLeading) {
                    VStack(spacing: 10) {
                        ForEach(editor.project.tracks) { track in lane(track) }
                    }
                    .padding(.vertical, 8)
                    Rectangle().fill(Theme.recordRed).frame(width: 2)
                        .offset(x: editor.x(forFrame: playback.currentFrame))
                        .allowsHitTesting(false)
                }
                .frame(width: max(800, editor.x(forFrame: editor.project.totalFrames) + 300), alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(height: laneHeight)
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
#endif
