import AppKit
import SwiftUI

@MainActor
struct ProjectsSettingsView: View {
    @ObservedObject var store: ProjectKnowledgeStore = .shared
    @State private var selectedID: UUID?
    @State private var notes = ""
    @State private var query = ""
    @State private var matches: [ProjectKnowledgeMatch] = []

    private var selected: KnowledgeProject? { store.projects.first { $0.id == selectedID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Project knowledge").font(.title2.bold())
                    Spacer()
                    Button("Add folder…", action: addFolder)
                }
                Text("Keep project documents, code and notes on this Mac. Choose the active project for the agent; only matching excerpts and its notes enter the request to your provider.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Active project", selection: Binding(
                    get: { store.activeProjectID }, set: { store.selectProject($0) }
                )) {
                    Text("No project").tag(UUID?.none)
                    ForEach(store.projects) { project in Text(project.name).tag(Optional(project.id)) }
                }
                ForEach(store.projects) { project in
                    Button {
                        selectedID = project.id; notes = project.notes; matches = []
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name).font(.headline)
                                Text(project.folder.path).font(.caption).lineLimit(1).truncationMode(.middle)
                                Text(project.indexedAt.map { "\(project.indexedFiles) files · Indexed \($0.formatted())" } ?? "Not indexed")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedID == project.id { Image(systemName: "checkmark") }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.bordered)
                }
                if let project = selected {
                    Divider()
                    HStack {
                        Text(project.name).font(.headline)
                        Spacer()
                        if store.indexingProjectID == project.id { ProgressView().controlSize(.small) }
                        Button("Reindex") { Task { await store.reindex(project.id) } }
                            .disabled(store.indexingProjectID != nil)
                        Button("Remove", role: .destructive) {
                            store.removeProject(project.id)
                            if !store.projects.contains(where: { $0.id == project.id }) { selectedID = nil; matches = [] }
                        }.disabled(store.indexingProjectID == project.id)
                    }
                    Text("Project notes").font(.subheadline.bold())
                    TextEditor(text: $notes).font(.body).frame(minHeight: 130)
                    Button("Save notes") { store.saveNotes(notes, projectID: project.id) }
                    HStack {
                        TextField("Search schema, code or documents", text: $query)
                            .onSubmit { matches = store.search(projectID: project.id, query: query) }
                        Button("Search") { matches = store.search(projectID: project.id, query: query) }
                    }
                    ForEach(matches) { match in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(match.citation).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(match.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Text("Reindex after changing source files. Search uses matching words, not semantic embeddings. Hidden files, symbolic links, build folders and common credential files are excluded. Review project notes before including confidential material.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = store.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            selectedID = store.activeProjectID ?? store.projects.first?.id
            notes = selected?.notes ?? ""
        }
    }

    private func addFolder() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.prompt = "Add project"
        guard picker.runModal() == .OK, let folder = picker.url,
              let id = store.addProject(name: folder.lastPathComponent, folder: folder) else { return }
        selectedID = id; notes = ""; matches = []
        Task { await store.reindex(id) }
    }
}
