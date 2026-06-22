#if os(macOS)
import SwiftUI

/// Desktop shell: a projects sidebar and the multi-track editor detail.
struct MacRootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var recordingService: RecordingService
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
            WorkspaceSidebar(projects: $projects, selectedID: $selectedID, editor: editor,
                             onNew: { promptNewProject() },
                             onRename: { renameTarget = $0; renameText = $0.name },
                             onDelete: { delete($0) },
                             onDeleteMany: { deleteMany($0) })
                .frame(minWidth: 240)
        } detail: {
            if let editor {
                MacEditorView(editor: editor)
            } else {
                placeholder
            }
        }
        .frame(minWidth: 940, minHeight: 580)
        // Crimson hairline frames the whole window while recording (Zone 1 cue).
        .overlay {
            if recordingService.isRecording {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.recordRed, lineWidth: 2)
                    .shadow(color: Theme.recordRed.opacity(0.6), radius: 6)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: recordingService.isRecording)
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

    private func deleteMany(_ ids: [Project.ID]) {
        let set = Set(ids)
        for project in projects where set.contains(project.id) { env.projectStore.delete(project) }
        if let sel = selectedID, set.contains(sel) { selectedID = nil; editor = nil }
        reload()
    }
}
#endif
