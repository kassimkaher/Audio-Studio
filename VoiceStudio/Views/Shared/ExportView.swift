import SwiftUI
import AVFoundation

/// Plays back an exported file in-app, independent of the project engine, with a
/// scrubbable transport (play/pause + seek slider).
@MainActor
final class ExportPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    var isScrubbing = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Loads (but doesn't play) a file so the slider/duration are ready.
    func prepare(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false; stopTimer() }
        else { p.play(); isPlaying = true; startTimer() }
    }

    func seek(to t: Double) {
        guard let p = player else { return }
        let clamped = max(0, min(t, duration))
        p.currentTime = clamped
        currentTime = clamped
    }

    func stop() {
        player?.stop(); player = nil; isPlaying = false; stopTimer()
        currentTime = 0; duration = 0
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, !self.isScrubbing else { return }
                self.currentTime = p.currentTime
            }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false; self.currentTime = 0; self.stopTimer() }
    }
}

struct ExportView: View {
    let project: Project
    @EnvironmentObject private var renderer: MixdownRenderer
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .m4a
    @State private var exportedURL: URL?
    @State private var errorMessage: String?
    @StateObject private var preview = ExportPreviewPlayer()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.screenBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        summaryCard
                        formatCard
                        renderButton
                        if renderer.isRendering { progressCard }
                        if let url = exportedURL { resultCard(url) }
                    }
                    .padding()
                }
            }
            .navigationTitle("Export")
            .inlineTitle()
            .onDisappear { preview.stop() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Export Failed",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(project.name).font(.title3.weight(.semibold))
                Label(formatTime(project.duration), systemImage: "clock")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                Label("\(project.tracks.count) tracks · mixdown applies all effects",
                      systemImage: "square.stack.3d.up")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var formatCard: some View {
        Card {
            VStack(spacing: 12) {
                ForEach(ExportFormat.allCases) { f in
                    Button { format = f } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(f.rawValue).font(.body.weight(.semibold))
                                Text(f.subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: format == f ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(12)
                        .background(format == f ? Theme.accent.opacity(0.12) : Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .sectionHeader("Format")
    }

    private var renderButton: some View {
        Button {
            Task { await render() }
        } label: {
            Label("Render Mixdown", systemImage: "waveform.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Theme.accent)
        .disabled(renderer.isRendering || project.totalFrames == 0)
    }

    private var progressCard: some View {
        Card {
            VStack(spacing: 10) {
                ProgressView(value: renderer.progress)
                    .tint(Theme.accent)
                Text("Rendering… \(Int(renderer.progress * 100))%")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func resultCard(_ url: URL) -> some View {
        Card {
            VStack(spacing: 12) {
                Label("Export ready", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                // Scrubbable preview transport.
                HStack(spacing: 10) {
                    Button { preview.toggle() } label: {
                        Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 30)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)

                    Text(formatTimecode(preview.currentTime))
                        .font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                    Slider(value: $preview.currentTime, in: 0...max(preview.duration, 0.01)) { editing in
                        preview.isScrubbing = editing
                        if !editing { preview.seek(to: preview.currentTime) }
                    }
                    .tint(Theme.accent)
                    Text(formatTimecode(preview.duration))
                        .font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                }
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentWarm)
            }
        }
    }

    private func render() async {
        preview.stop()
        exportedURL = nil
        do {
            let url = try await renderer.render(project: project, format: format)
            exportedURL = url
            preview.prepare(url)        // load so the seek slider is ready
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
