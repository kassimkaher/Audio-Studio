import SwiftUI

struct TrackHeaderView: View {
    @ObservedObject var editor: ProjectEditorViewModel
    let track: Track
    var onEditEffects: () -> Void
    var onDelete: () -> Void

    @State private var renaming = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: track.kind == .vocal ? "mic.fill" : "music.note")
                    .font(.caption)
                    .foregroundStyle(track.kind == .vocal ? Theme.accent : Theme.accentWarm)
                Text(track.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Menu {
                    Button { onEditEffects() } label: { Label("Effects", systemImage: "slider.horizontal.3") }
                    Button { draftName = track.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button { editor.duplicateTrack(track.id) } label: { Label("Duplicate Track", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { onDelete() } label: { Label("Delete Track", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.caption)
                }
                .tint(Theme.textSecondary)
            }

            HStack(spacing: 6) {
                pill("M", active: track.isMuted, color: Theme.recordRed) { editor.toggleMute(track.id) }
                pill("S", active: track.isSoloed, color: Theme.accentWarm) { editor.toggleSolo(track.id) }
                Button(action: onEditEffects) { Image(systemName: "slider.horizontal.3").font(.caption2) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }

            Slider(value: Binding(
                get: { track.volume },
                set: { editor.setVolume($0, forTrack: track.id) }
            ), in: 0...1.5)
            .controlSize(.mini).tint(Theme.accent)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.trailing, 6)
        .alert("Rename Track", isPresented: $renaming) {
            TextField("Track name", text: $draftName)
            Button("Save") { editor.renameTrack(track.id, to: draftName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func pill(_ label: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.caption2.weight(.bold))
                .frame(width: 20, height: 20)
                .background(active ? color : Theme.surface)
                .foregroundStyle(active ? .black : Theme.textSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}
