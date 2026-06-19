#if os(macOS)
import SwiftUI

/// Desktop shell: a projects sidebar and the multi-track editor detail.
struct MacRootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var projects: [Project] = []
    @State private var selectedID: Project.ID?
    @State private var editor: ProjectEditorViewModel?
    @State private var didReset = false
    @State private var showNewPrompt = false
    @State private var newName = ""
    @State private var renameTarget: Project?
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 240)
        } detail: {
            if let editor {
                MacEditorView(editor: editor)
            } else {
                placeholder
            }
        }
        .frame(minWidth: 940, minHeight: 580)
        .onAppear {
            if env.resetForTesting && !didReset {
                env.projectStore.allProjects().forEach { env.projectStore.delete($0) }
                didReset = true
            }
            reload()
        }
        .onChange(of: selectedID) { _ in openSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .vsNewProject)) { _ in promptNewProject() }
        .alert("New Project", isPresented: $showNewPrompt) {
            TextField("Project name", text: $newName)
            Button("Create") { createProject(named: newName) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Name your new project.") }
        .alert("Rename Project", isPresented: Binding(get: { renameTarget != nil },
                                                      set: { if !$0 { renameTarget = nil } })) {
            TextField("Project name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedID) {
            Section("Projects") {
                ForEach(projects) { project in
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).font(.body)
                            Text("\(project.tracks.count) tracks · \(formatTime(project.duration))")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .tag(project.id)
                    .contextMenu {
                        Button { renameTarget = project; renameText = project.name } label: { Label("Rename", systemImage: "pencil") }
                        Divider()
                        Button(role: .destructive) { delete(project) } label: { Label("Delete Project", systemImage: "trash") }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { promptNewProject() } label: {
                Label("New Project", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .padding(8)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle").font(.system(size: 64)).foregroundStyle(Theme.accent)
            Text("Select or create a project").font(.title3).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func reload() {
        projects = env.projectStore.allProjects()
        if selectedID == nil { selectedID = projects.first?.id }
        if editor == nil { openSelected() }
    }

    private func openSelected() {
        if let id = selectedID, let p = projects.first(where: { $0.id == id }) {
            editor = ProjectEditorViewModel(project: p, env: env)
        } else {
            editor = nil
        }
    }

    private func promptNewProject() {
        newName = "New Project"
        showNewPrompt = true
    }

    private func createProject(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project.makeDefault(name: trimmed.isEmpty ? "New Project" : trimmed)
        try? env.projectStore.save(project)
        projects = env.projectStore.allProjects()
        selectedID = project.id
        editor = ProjectEditorViewModel(project: project, env: env)
    }

    private func commitRename() {
        guard var p = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !trimmed.isEmpty else { return }
        p.name = trimmed
        try? env.projectStore.save(p)
        if editor?.project.id == p.id { editor?.renameProject(trimmed) }
        reload()
    }

    private func delete(_ project: Project) {
        env.projectStore.delete(project)
        if selectedID == project.id { selectedID = nil; editor = nil }
        reload()
    }
}
#endif
