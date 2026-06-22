#if os(macOS)
import SwiftUI

/// Zone 2 — one workspace explorer consolidating Projects, project Assets, Vocal
/// Profiles (presets + saved Modes) and the IR acoustic-space library. Clicking a
/// profile or space applies it to the current selection in the open editor.
struct WorkspaceSidebar: View {
    @Binding var projects: [Project]
    @Binding var selectedID: Project.ID?
    var editor: ProjectEditorViewModel?
    var onNew: () -> Void
    var onRename: (Project) -> Void
    var onDelete: (Project) -> Void
    var onDeleteMany: ([Project.ID]) -> Void

    @EnvironmentObject private var presetStore: PresetStore
    @EnvironmentObject private var irLoader: IRLoader

    @State private var selecting = false
    @State private var picked: Set<Project.ID> = []
    @State private var showBulkConfirm = false

    var body: some View {
        List(selection: $selectedID) {
            workspaceHeader
            projectsSection
            if editor != nil {
                assetsSection
                profilesSection
                spacesSection
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)     // kill the translucent sidebar material
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                Divider().overlay(Theme.hairline)
                HStack(spacing: 16) {
                    Label("Settings", systemImage: "gearshape").font(.caption)
                    Label("Support", systemImage: "questionmark.circle").font(.caption)
                    Spacer()
                }
                .foregroundStyle(Theme.textSecondary).padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Theme.accentWarm.opacity(0.25))
                    .overlay(Image(systemName: "waveform").font(.caption).foregroundStyle(Theme.accentWarm))
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Workspace Explorer")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accentWarm)
                    Text("Vocal Production Hub")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                }
            }
            Button { if let editor { editor.addTrack() } else { onNew() } } label: {
                Label("Add New Track", systemImage: "plus").frame(maxWidth: .infinity)
                    .font(.system(size: 13, weight: .medium)).padding(.vertical, 7)
                    .background(Theme.surfaceElevated).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textPrimary)
        }
        .listRowBackground(Color.clear)
        .padding(.vertical, 4)
    }

    // MARK: Projects

    private var projectsSection: some View {
        Section {
            if !selecting {
                Button(action: onNew) {
                    Label("New Project", systemImage: "plus.circle").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            ForEach(projects) { project in
                if selecting { selectableRow(project) }
                else { projectRow(project).tag(project.id) }
            }
        } header: {
            HStack {
                Text("Projects")
                Spacer()
                if selecting {
                    Button(role: .destructive) { showBulkConfirm = true } label: {
                        Text("Delete \(picked.count)")
                    }.disabled(picked.isEmpty).buttonStyle(.plain).foregroundStyle(picked.isEmpty ? Theme.textSecondary : Theme.recordRed)
                    Button("Done") { selecting = false; picked = [] }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                } else if projects.count > 1 {
                    Button("Select") { selecting = true }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
            }.font(.caption)
        }
        .confirmationDialog("Delete \(picked.count) project\(picked.count == 1 ? "" : "s")? Their audio files are removed too.",
                            isPresented: $showBulkConfirm, titleVisibility: .visible) {
            Button("Delete \(picked.count)", role: .destructive) {
                onDeleteMany(Array(picked)); selecting = false; picked = []
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func projectRow(_ project: Project) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.body)
                Text("\(project.tracks.count) tracks · \(formatTime(project.duration))")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .contextMenu {
            Button { onRename(project) } label: { Label("Rename", systemImage: "pencil") }
            Button { selecting = true; picked = [project.id] } label: { Label("Select…", systemImage: "checkmark.circle") }
            Divider()
            Button(role: .destructive) { onDelete(project) } label: { Label("Delete Project", systemImage: "trash") }
        }
    }

    private func selectableRow(_ project: Project) -> some View {
        Button {
            if picked.contains(project.id) { picked.remove(project.id) } else { picked.insert(project.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: picked.contains(project.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked.contains(project.id) ? Theme.accent : Theme.textSecondary)
                Text(project.name).font(.body).foregroundStyle(Theme.textPrimary)
                Spacer()
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: Assets

    private var assetsSection: some View {
        Section("Assets") {
            if let editor, !editor.project.sources.isEmpty {
                ForEach(editor.project.sources) { src in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(src.fileName).font(.caption).lineLimit(1)
                            Text(formatTime(src.duration)).font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                    } icon: { Image(systemName: "waveform.circle").foregroundStyle(Theme.textSecondary) }
                }
            } else {
                Text("No audio yet").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Button { NotificationCenter.default.post(name: .vsImport, object: nil) } label: {
                Label("Import Audio…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
    }

    // MARK: Vocal Profiles

    private var profilesSection: some View {
        Section("Vocal Profiles") {
            ForEach(PresetLibrary.all) { preset in
                chip(symbol: preset.symbol, name: preset.name, tint: Theme.accentWarm) {
                    editor?.applyChainToSelection(preset.chain)
                }
            }
            ForEach(presetStore.presets) { mode in
                chip(symbol: "wand.and.stars", name: mode.name, tint: Theme.accent) {
                    editor?.applyChainToSelection(mode.chain)
                }
            }
        }
    }

    // MARK: IR Spaces

    private var spacesSection: some View {
        Section("IR Spaces") {
            ForEach(irLoader.available) { ir in
                chip(symbol: "building.columns", name: ir.name, tint: Theme.accent) {
                    editor?.applyIR(ir.id)
                }
            }
        }
    }

    private func chip(symbol: String, name: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
                Text(name).font(.callout).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Apply to the selected track or clip")
    }
}
#endif
