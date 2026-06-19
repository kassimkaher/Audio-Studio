import SwiftUI

struct ProjectLibraryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var projects: [Project] = []
    @State private var path: [Project] = []
    @State private var didReset = false
    @State private var showNewPrompt = false
    @State private var newName = ""
    @State private var renameTarget: Project?
    @State private var renameText = ""

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.screenBackground.ignoresSafeArea()
                if projects.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Voice Studio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { promptNew() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New project")
                }
            }
            .navigationDestination(for: Project.self) { project in
                ProjectEditorView(editor: ProjectEditorViewModel(project: project, env: env))
            }
            .alert("New Project", isPresented: $showNewPrompt) {
                TextField("Project name", text: $newName)
                Button("Create") { createAndOpen(named: newName) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Name your new project.") }
            .alert("Rename Project", isPresented: Binding(get: { renameTarget != nil },
                                                          set: { if !$0 { renameTarget = nil } })) {
                TextField("Project name", text: $renameText)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
        }
        .onAppear {
            if env.resetForTesting && !didReset {
                env.projectStore.allProjects().forEach { env.projectStore.delete($0) }
                didReset = true
            }
            reload()
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(projects) { project in
                    Button { path.append(project) } label: {
                        ProjectCardView(project: project)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { renameTarget = project; renameText = project.name } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) { delete(project) } label: {
                            Label("Delete Project", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 60)).foregroundStyle(Theme.accent)
            Text("No projects yet").font(.title3.weight(.semibold))
            Text("Create a project to start recording and editing.")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button { promptNew() } label: {
                Label("New Project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .accessibilityIdentifier("NewProjectButton")
        }
        .padding(40)
    }

    private func reload() { projects = env.projectStore.allProjects() }

    private func promptNew() { newName = "New Project"; showNewPrompt = true }

    private func createAndOpen(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project.makeDefault(name: trimmed.isEmpty ? "New Project" : trimmed)
        try? env.projectStore.save(project)
        reload()
        path.append(project)
    }

    private func commitRename() {
        guard var p = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !trimmed.isEmpty else { return }
        p.name = trimmed
        try? env.projectStore.save(p)
        reload()
    }

    private func delete(_ project: Project) {
        env.projectStore.delete(project)
        reload()
    }
}

struct ProjectCardView: View {
    let project: Project

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.18))
                Image(systemName: "waveform").font(.title2).foregroundStyle(Theme.accent)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.headline).foregroundStyle(Theme.textPrimary)
                Text("\(project.tracks.count) tracks · \(project.clipCount) clips · \(formatTime(project.duration))")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
