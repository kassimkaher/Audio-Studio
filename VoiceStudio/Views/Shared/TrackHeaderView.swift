import SwiftUI

struct TrackHeaderView: View {
    @ObservedObject var editor: ProjectEditorViewModel
    let track: Track
    var onEditEffects: () -> Void
    var onDelete: () -> Void

    @State private var renaming = false
    @State private var draftName = ""

    /// Raddah / crowd lanes carry the warm gold identity.
    private var isWarm: Bool {
        track.kind == .background
            || track.name.contains("ردّة")
            || track.name.range(of: "raddah", options: .caseInsensitive) != nil
    }
    private var laneAccent: Color { isWarm ? Theme.accentWarm : Theme.accent }
    private var volDb: String {
        track.volume <= 0.001 ? "-∞" : String(format: "%.1fdB", 20 * log10(track.volume))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isWarm ? "person.2.wave.2.fill" : "mic.fill")
                    .font(.caption)
                    .foregroundStyle(laneAccent)
                    .neonGlow(laneAccent, radius: 4)
                Text(track.name).font(.caption.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(isWarm ? Theme.accentWarm : Theme.textPrimary)
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

            if isWarm {
                Text("MAJLIS CORE EFFECT ACTIVE")
                    .font(.system(size: 8, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Theme.accentWarm)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Theme.accentWarm.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            HStack(spacing: 6) {
                pill("M", active: track.isMuted, color: Theme.recordRed) { editor.toggleMute(track.id) }
                pill("S", active: track.isSoloed, color: Theme.accentWarm) { editor.toggleSolo(track.id) }
                pill("R", active: track.isArmed, color: Theme.recordRed) { editor.toggleArm(track.id) }
                Spacer()
                Text("VOL: \(volDb)")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(laneAccent.opacity(0.85))
            }

            Slider(value: Binding(
                get: { track.volume },
                set: { editor.setVolume($0, forTrack: track.id) }
            ), in: 0...1.5)
            .controlSize(.mini).tint(Theme.accent)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Theme.surfaceElevated
                if isWarm { Theme.accentWarm.opacity(0.10) }   // gold ambient tint
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Armed = red ring; selected = accent ring; else a faint lane-accent edge.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(track.isArmed ? Theme.recordRed
                              : (editor.selectedTrackID == track.id ? laneAccent
                                 : (isWarm ? Theme.accentWarm.opacity(0.4) : Theme.hairline)),
                              lineWidth: track.isArmed || editor.selectedTrackID == track.id ? 1.5 : 1)
        )
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
