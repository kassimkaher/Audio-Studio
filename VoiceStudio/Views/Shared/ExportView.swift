import SwiftUI

struct ExportView: View {
    let project: Project
    @EnvironmentObject private var renderer: MixdownRenderer
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .m4a
    @State private var exportedURL: URL?
    @State private var errorMessage: String?

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
        exportedURL = nil
        do {
            let url = try await renderer.render(project: project, format: format)
            exportedURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
