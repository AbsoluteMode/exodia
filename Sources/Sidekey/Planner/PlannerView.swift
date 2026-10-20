import SwiftUI

struct PlannerView: View {
    @ObservedObject var store: PlannerStore
    @ObservedObject var navigation: PlannerNavigation
    @ObservedObject var connections: CalendarConnections = .shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Label("Planner", systemImage: "square.grid.2x2.fill")
                    .font(.title2.weight(.semibold)).padding(.top, 14)
                VStack(spacing: 6) {
                    ForEach(PlannerSection.allCases, id: \.self) { section in
                        Button { navigation.section = section } label: {
                            HStack {
                                Label(section.rawValue, systemImage: section == .tasks ? "checklist" : "calendar")
                                Spacer()
                                if section == .tasks {
                                    Text("\(store.archive.tasks.filter { !$0.completed }.count)")
                                        .foregroundStyle(MacSettingsTheme.text2).monospacedDigit()
                                }
                            }
                            .padding(10).contentShape(Rectangle())
                            .background(navigation.section == section ? Color.accentColor.opacity(0.17) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                        .accessibilityAddTraits(navigation.section == section ? .isSelected : [])
                    }
                }
                Spacer()
                Label("Stored on this Mac", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(MacSettingsTheme.text2)
            }
            .padding(18).frame(width: 185)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            Divider()
            VStack(spacing: 0) {
                if let error = store.errorMessage {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                        Spacer()
                        if !store.canWrite { Button("Retry") { store.reload() } }
                    }.padding(14).background(Color.orange.opacity(0.12))
                }
                if navigation.section == .tasks {
                    PlannerTasksView(store: store, draft: $navigation.taskDraft)
                } else {
                    PlannerCalendarView(store: store, navigation: navigation, connections: connections)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct PlannerTasksView: View {
    @ObservedObject var store: PlannerStore
    @Binding var draft: String
    @State private var query = ""
    @State private var showCompleted = false
    @State private var editing: PlannerTask?
    @State private var deleting: PlannerTask?
    @FocusState private var inputFocused: Bool

    private var tasks: [PlannerTask] {
        store.archive.tasks.filter {
            $0.completed == showCompleted && (query.isEmpty ||
                $0.title.localizedCaseInsensitiveContains(query))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("To-do").font(.largeTitle.weight(.bold))
                    Text("A little less to keep in your head.").foregroundStyle(MacSettingsTheme.text2)
                }
                Spacer()
                Picker("Tasks", selection: $showCompleted) {
                    Text("Active").tag(false)
                    Text("Completed").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                .accessibilityLabel("Tasks")
            }
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                TextField("Add a task, then press Return", text: $draft)
                    .textFieldStyle(.plain).focused($inputFocused).onSubmit(addTask)
                    .accessibilityLabel("New task")
                Button("Add", action: addTask)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canWrite)
            }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("\(tasks.count) \(showCompleted ? "completed" : "active")")
                    .font(.callout.weight(.medium)).foregroundStyle(MacSettingsTheme.text2)
                Spacer()
                TextField("Search tasks", text: $query).textFieldStyle(.roundedBorder).frame(width: 190)
            }
            if tasks.isEmpty {
                PlannerEmptyState(symbol: showCompleted ? "checkmark.circle" : "checklist",
                    title: query.isEmpty ? (showCompleted ? "No completed tasks yet" : "You’re all caught up") : "No matching tasks",
                    subtitle: query.isEmpty ? "Add a task above whenever something comes to mind." : "Try a different search.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(tasks) { task in
                            HStack(spacing: 12) {
                                Button {
                                    var changed = task
                                    changed.completed.toggle()
                                    _ = store.saveTask(changed)
                                } label: {
                                    Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                                        .font(.title2).foregroundStyle(task.completed ? Color.accentColor : .secondary)
                                }.buttonStyle(.plain)
                                .accessibilityLabel(task.completed ? "Reopen task: \(task.title)" : "Complete task: \(task.title)")
                                Text(task.title).strikethrough(task.completed).frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                Button { editing = task } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.borderless).help("Edit task").accessibilityLabel("Edit task: \(task.title)")
                                Button { deleting = task } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help("Delete task").accessibilityLabel("Delete task: \(task.title)")
                            }
                            .padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            .disabled(!store.canWrite)
                        }
                    }
                }
            }
        }
        .padding(28)
        .onAppear { inputFocused = true }
        .sheet(item: $editing) { task in
            PlannerTaskEditor(task: task, store: store)
        }
        .alert("Delete task?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let task = deleting { _ = store.deleteTask(task.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text(deleting?.title ?? "") }
    }

    private func addTask() {
        if store.saveTask(PlannerTask(title: draft)) { draft = ""; showCompleted = false; inputFocused = true }
    }
}

private struct PlannerTaskEditor: View {
    @State var task: PlannerTask
    @ObservedObject var store: PlannerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit task").font(.title2.bold())
            TextField("Task", text: $task.title).textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let message = store.errorMessage { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canWrite)
            }
        }.padding(24).frame(width: 420)
    }

    private func save() { if store.saveTask(task) { dismiss() } }
}

struct PlannerEmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(MacSettingsTheme.text2)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).foregroundStyle(MacSettingsTheme.text2).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}
