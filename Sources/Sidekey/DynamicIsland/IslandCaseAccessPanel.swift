import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Connect opens the client picker; a client icon opens that client's policy.
/// No registration is created until the person saves the scope and mode.
struct IslandCaseAccessPanel: View {
    @ObservedObject var viewModel: CaseViewModel
    var onBack: () -> Void

    @State private var draft: CaseAccessDraft?
    @State private var availableClients: [CaseKnownClient] = []
    @State private var isLoadingClients = true
    @State private var lastError: String?
    @State private var isBusy = false

    init(viewModel: CaseViewModel, onBack: @escaping () -> Void,
         appID: UUID? = nil) {
        self.viewModel = viewModel
        self.onBack = onBack
        _draft = State(initialValue: appID.flatMap { id in
            viewModel.registrations.first { $0.id == id }.map(CaseAccessDraft.init)
        })
    }

    static let title = "Доступ к ключам"
    static let explanation = "Accept — спрашивать. Bypass — без запроса."
    static let footer = "Подключение и Bypass — через Touch ID."
    static let sharedTerminalHint = "Bypass действует и для ваших команд в этом терминале."
    static let builtInSubtitle = "встроенный агент Whytap"
    static let inheritLabel = "По умолчанию"

    var body: some View {
        VStack(spacing: 7) {
            header
            if let lastError { messageLine(lastError) }
            ForEach(viewModel.clientSetupProblems, id: \.self) { messageLine($0) }
            if !viewModel.clientSetupProblems.isEmpty, let id = draft?.appID {
                Button("Повторить настройку агента") {
                    perform { _ = try await viewModel.retryClientSetup(for: id) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .disabled(isBusy)
                .accessibilityIdentifier("case.connect.retry")
            }
            if draft != nil {
                policyEditor
            } else {
                clientPicker
            }
        }
        .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)
        .padding(.top, IslandCaseVaultStyle.topPadding)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            guard draft == nil else { isLoadingClients = false; return }
            availableClients = await viewModel.availableClientsToRegister()
            guard !Task.isCancelled else { return }
            isLoadingClients = false
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button {
                if draft?.appID == nil, draft != nil {
                    draft = nil
                    lastError = nil
                } else { onBack() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel(draft?.appID == nil && draft != nil ? "Назад к агентам" : "Назад к ключам")
            .accessibilityIdentifier("case.access.back")
            Text(draft?.name ?? "Connect")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if isBusy { ProgressView().controlSize(.small) }
        }
        .foregroundStyle(.white.opacity(0.92))
        .frame(height: 26)
    }

    private var clientPicker: some View {
        IslandCaseClientPicker(clients: availableClients, isLoading: isLoadingClients,
                              onChoose: { draft = CaseAccessDraft(identity: $0.identity, name: $0.displayName) },
                              onChooseProgram: chooseProgram)
    }

    private var policyEditor: some View {
        VStack(spacing: 7) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text(Self.title).font(.system(size: 10, weight: .semibold))
                    HStack {
                        Text("Режим").font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 8)
                        CaseModeSegment(options: [.init(label: "Accept", value: .approve), .init(label: "Bypass", value: .bypass)],
                                        selected: draft?.mode, identifierPrefix: "case.access.mode") {
                            if let mode = $0 { draft?.mode = mode }
                        }
                    }
                    caption(Self.explanation)
                    HStack(spacing: 5) {
                        scopeButton("Все проекты", all: true)
                        scopeButton("Выбранные", all: false)
                    }
                    if draft?.allProjects == true {
                        caption("Все текущие и новые проекты.")
                    } else {
                        caption(draft?.projectIDs.isEmpty == true ? "Проекты не выбраны — доступ закрыт." : "Доступ только к отмеченным проектам.")
                        LazyVStack(spacing: 2) {
                            ForEach(viewModel.accessProjects) { project in
                                projectChoice(project)
                            }
                        }
                    }
                    if let draft, !draft.projectModes.isEmpty {
                        caption("Отдельные режимы проектов")
                        ForEach(viewModel.accessProjects.filter { draft.projectModes[$0.id] != nil }) { project in
                            HStack {
                                Text(project.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Menu {
                                    Button(Self.inheritLabel) { self.draft?.projectModes[project.id] = nil }
                                    Button("Accept") { self.draft?.projectModes[project.id] = .approve }
                                    Button("Bypass") { self.draft?.projectModes[project.id] = .bypass }
                                } label: {
                                    Text(draft.projectModes[project.id] == .bypass ? "Bypass" : "Accept")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            .font(.system(size: 10))
                        }
                    }
                    if let draft, Self.showsSharedTerminalHint(app: draft.registration, known: CaseKnownClient(identity: draft.identity)) {
                        caption(Self.sharedTerminalHint)
                    }
                    caption(Self.footer)
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 2)
            }
            .disabled(isBusy)
            HStack(spacing: 8) {
                if let appID = draft?.appID {
                    Button("Отключить") {
                        perform {
                            _ = try await viewModel.unregisterApp(appID)
                            onBack()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("case.access.unregister")
                }
                Spacer(minLength: 0)
                Button(action: save) {
                    Text(draft?.appID == nil ? "Connect" : "Сохранить")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(Color(red: 0.18, green: 0.43, blue: 0.96)))
                        .contentShape(Capsule())
                }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("case.access.save")
            }
            .font(.system(size: 11, weight: .medium))
            .disabled(isBusy || (draft?.appID == nil && draft?.allProjects == false && draft?.projectIDs.isEmpty == true))
        }
    }

    private func scopeButton(_ title: String, all: Bool) -> some View {
        let selected = draft?.allProjects == all
        return Button { draft?.allProjects = all } label: {
            Text(title)
                .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
                .frame(maxWidth: .infinity)
                .frame(height: 27)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(selected ? 0.17 : 0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(all ? "case.access.scope.all" : "case.access.scope.selected")
    }

    private func projectChoice(_ project: CaseProject) -> some View {
        let selected = draft?.projectIDs.contains(project.id) == true
        return Button {
            if selected { draft?.projectIDs.remove(project.id) }
            else { draft?.projectIDs.insert(project.id) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Color.blue : .white.opacity(0.7))
                Text(project.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 4)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("case.access.scope.project.\(project.id)")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageLine(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color(red: 1, green: 0.65, blue: 0.6))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        guard let draft else { return }
        perform {
            if let id = draft.appID {
                try await viewModel.setAccess(for: id, mode: draft.mode, projects: draft.scope, projectModes: draft.projectModes)
                onBack()
            } else {
                let result = try await viewModel.registerApp(draft.identity, name: draft.name, mode: draft.mode, projects: draft.scope)
                availableClients.removeAll { $0.identity == draft.identity }
                if result.problems.isEmpty { onBack() }
                else { self.draft?.appID = result.appID }
            }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        Task { @MainActor in
            defer { isBusy = false }
            do { try await action() }
            catch { lastError = Self.message(for: error) }
        }
    }

    private func chooseProgram() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Выбрать"
        panel.message = "Программа, которой можно давать ключи Case"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let choice = Self.programChoice(for: url) else { return }
            draft = CaseAccessDraft(identity: choice.identity, name: choice.name)
        }
    }

    static func showsSharedTerminalHint(app: CaseAppRegistration, known: CaseKnownClient?) -> Bool {
        let shared = known?.hasSharedTerminal ?? { if case .executablePath = app.identity { return true }; return false }()
        return shared && (app.defaultMode == .bypass || app.projectModes.values.contains(.bypass))
    }

    static func programChoice(for url: URL) -> (identity: CaseAppIdentity, name: String)? {
        let resolved = url.resolvingSymlinksInPath()
        let isApp = resolved.pathExtension == "app"
        guard isApp || FileManager.default.isExecutableFile(atPath: resolved.path) else { return nil }
        let identity = CaseAppIdentity.executablePath(resolved.path)
        if let known = CaseKnownClient(identity: identity) { return (known.identity, known.displayName) }
        return (identity, isApp ? resolved.deletingPathExtension().lastPathComponent : resolved.lastPathComponent)
    }

    static func message(for error: Error) -> String {
        switch error as? CaseViewModelError {
        case .authenticationFailed: return "Touch ID не подтверждён — ничего не изменено"
        case .alreadyRegistered: return "Это приложение уже зарегистрировано"
        case .invalidAppName: return "Эту программу нельзя зарегистрировать"
        case .invalidMinutes: return "Разрешение: от 1 до 240 минут"
        case .locked: return "Case заблокирован"
        case .missingApp, .missingProject: return "Уже удалено"
        default: return "Не удалось сохранить"
        }
    }
}

struct IslandCaseClientPicker: View {
    let clients: [CaseKnownClient]
    let isLoading: Bool
    let onChoose: (CaseKnownClient) -> Void
    let onChooseProgram: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                caption("Подключите агента, чтобы он мог использовать ключи в командах.")
                    .padding(.bottom, 4)
                if isLoading {
                    caption("Ищу приложения…")
                } else if clients.isEmpty {
                    caption("Все найденные агенты уже подключены. Можно выбрать другую программу.")
                }
                ForEach(clients, id: \.self) { client in
                    Button {
                        onChoose(client)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                            Text(client.displayName).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("case.connect.\(client.rawValue)")
                }
                Button("Выбрать программу…", action: onChooseProgram)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("case.connect.chooseProgram")
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }


}

private struct CaseAccessDraft {
    var appID: UUID?
    var identity: CaseAppIdentity
    var name: String
    var mode: CaseAccessMode = .approve
    var allProjects = true
    var projectIDs: Set<UUID> = []
    var projectModes: [UUID: CaseAccessMode] = [:]

    init(identity: CaseAppIdentity, name: String) {
        self.identity = identity
        self.name = name
    }

    init(_ app: CaseAppRegistration) {
        appID = app.id
        identity = app.identity
        name = app.displayName
        mode = app.defaultMode
        allProjects = app.allowedProjectIDs == nil
        projectIDs = app.allowedProjectIDs ?? []
        projectModes = app.projectModes
    }

    var scope: Set<UUID>? { allProjects ? nil : projectIDs }
    var registration: CaseAppRegistration {
        CaseAppRegistration(id: appID ?? UUID(), displayName: name, identity: identity, defaultMode: mode,
                            projectModes: projectModes, createdAt: .distantPast, allowedProjectIDs: scope)
    }
}

/// Small segmented control in the island style. Bypass is highlighted amber.
struct CaseModeSegment: View {
    struct Option {
        let label: String
        let value: CaseAccessMode?
    }

    let options: [Option]
    let selected: CaseAccessMode?
    let identifierPrefix: String
    var segmentPadding: CGFloat = 6
    let onSelect: (CaseAccessMode?) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isOn = option.value == selected
                Button {
                    if !isOn { onSelect(option.value) }
                } label: {
                    Text(option.label)
                        .font(.system(size: 9.5, weight: isOn ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(foreground(option, isOn: isOn))
                        .padding(.horizontal, segmentPadding)
                        .frame(height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(background(option, isOn: isOn))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifierPrefix).\(option.value?.rawValue ?? "inherit")")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
        .fixedSize()
    }

    private func foreground(_ option: Option, isOn: Bool) -> Color {
        guard isOn else { return .white.opacity(0.55) }
        return option.value == .bypass ? Color(red: 1.0, green: 0.81, blue: 0.48) : .white
    }

    private func background(_ option: Option, isOn: Bool) -> Color {
        guard isOn else { return .clear }
        return option.value == .bypass ? Color(red: 0.35, green: 0.23, blue: 0.07) : Color.white.opacity(0.16)
    }
}
