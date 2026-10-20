import AppKit
import SwiftUI

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

    static let sharedTerminalHint = "Bypass действует и для ваших команд в этом терминале."
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
                .buttonStyle(CaseAccessButtonStyle())
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
            .buttonStyle(CaseAccessButtonStyle())
            .disabled(isBusy)
            .accessibilityLabel(draft?.appID == nil && draft != nil ? "Назад к агентам" : "Назад к ключам")
            .accessibilityIdentifier("case.access.back")
            if let draft {
                CaseAppBrandIcon(identity: draft.identity, size: 17, color: .white.opacity(0.92))
            }
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
                              hasConnectedClients: viewModel.registrations.contains {
                                  CaseKnownClient(identity: $0.identity).map { CaseKnownClient.connectableClients.contains($0) } ?? false
                              },
                              onChoose: { draft = CaseAccessDraft(identity: $0.identity, name: $0.displayName) })
    }

    private var policyEditor: some View {
        VStack(spacing: 7) {
            ScrollView {
                VStack(spacing: 8) {
                    CaseAccessSection(title: "Режим доступа") {
                        HStack(spacing: 5) {
                            modeButton("Accept", detail: "Спрашивать", mode: .approve)
                            modeButton("Bypass", detail: "Без запроса", mode: .bypass)
                        }
                        if let draft, Self.showsSharedTerminalHint(app: draft.registration, known: CaseKnownClient(identity: draft.identity)) {
                            Label(Self.sharedTerminalHint, systemImage: "exclamationmark.shield")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(red: 1, green: 0.81, blue: 0.48))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    CaseAccessSection(title: "Проекты") {
                        HStack(spacing: 5) {
                            scopeButton("Все проекты", all: true)
                            scopeButton("Выбранные", all: false)
                        }
                        if draft?.allProjects == true {
                            caption("Текущие и новые проекты")
                        } else {
                            if draft?.projectIDs.isEmpty == true {
                                caption("Выберите проекты для доступа")
                            }
                            LazyVStack(spacing: 2) {
                                ForEach(viewModel.accessProjects) { project in projectChoice(project) }
                            }
                        }
                    }
                    if let draft, !draft.projectModes.isEmpty {
                        CaseAccessSection(title: "Отдельные режимы") {
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
                    }
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
                    .buttonStyle(CaseAccessButtonStyle())
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("case.access.unregister")
                }
                Spacer(minLength: 0)
                Button(action: save) {
                    HStack(spacing: 5) {
                        Image(systemName: "touchid").accessibilityHidden(true)
                        Text(draft?.appID == nil ? "Connect" : "Сохранить")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Color(red: 0.18, green: 0.43, blue: 0.96)))
                    .contentShape(Capsule())
                }
                .buttonStyle(CaseAccessButtonStyle(cornerRadius: 14))
                .help("Подключение, расширение доступа и Bypass подтверждаются через Touch ID")
                .accessibilityHint("Подключение, расширение доступа и Bypass подтверждаются через Touch ID")
                .accessibilityIdentifier("case.access.save")
            }
            .font(.system(size: 11, weight: .medium))
            .disabled(isBusy || (draft?.appID == nil && draft?.allProjects == false && draft?.projectIDs.isEmpty == true))
        }
    }

    private func modeButton(_ title: String, detail: String, mode: CaseAccessMode) -> some View {
        let selected = draft?.mode == mode
        let tint = mode == .bypass ? Color(red: 1, green: 0.81, blue: 0.48) : .white
        return Button { draft?.mode = mode } label: {
            VStack(spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 10))
            }
            .foregroundStyle(selected ? tint : .white.opacity(0.80))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? tint.opacity(0.14) : .white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? tint.opacity(0.55) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(CaseAccessButtonStyle())
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("case.access.mode.\(mode.rawValue)")
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
        .buttonStyle(CaseAccessButtonStyle())
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
        .buttonStyle(CaseAccessButtonStyle())
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

    static func showsSharedTerminalHint(app: CaseAppRegistration, known: CaseKnownClient?) -> Bool {
        let shared = known?.hasSharedTerminal ?? { if case .executablePath = app.identity { return true }; return false }()
        return shared && (app.defaultMode == .bypass || app.projectModes.values.contains(.bypass))
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

/// Sections contain their own explanations; no loose footnotes between controls.
private struct CaseAccessSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
    }
}

struct IslandCaseClientPicker: View {
    let clients: [CaseKnownClient]
    let isLoading: Bool
    var hasConnectedClients = false
    let onChoose: (CaseKnownClient) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Ищу агентов…").font(.system(size: 11))
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
                } else if clients.isEmpty {
                    CaseAccessSection(title: hasConnectedClients ? "Агенты уже подключены" : "Агенты не найдены") {
                        Text(hasConnectedClients
                             ? "Нажмите логотип агента в Case, чтобы изменить его права."
                             : "Установите OpenCode или Cursor, затем откройте Connect снова.")
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(clients, id: \.self) { client in
                    CaseClientChoice(client: client) { onChoose(client) }
                }
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 2)
        }
    }
}

private struct CaseClientChoice: View {
    let client: CaseKnownClient
    let onChoose: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: onChoose) {
            HStack(spacing: 10) {
                CaseAppBrandIcon(identity: client.identity, size: 22, color: .white.opacity(0.92))
                    .frame(width: 26)
                Text(client.displayName).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused && isEnabled ? .white.opacity(0.8) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(CaseAccessButtonStyle())
        .focused($focused)
        .help("Выбрать проекты и режим доступа для \(client.displayName)")
        .accessibilityLabel("\(client.displayName), настроить доступ к ключам")
        .accessibilityIdentifier("case.connect.\(client.rawValue)")
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

/// All custom/plain Case controls share feedback over their entire hit target.
struct CaseAccessButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                CaseAccessInteractionOverlay(hovering: hovering, pressed: configuration.isPressed,
                                             focused: isFocused, enabled: isEnabled, cornerRadius: cornerRadius)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

/// Explicit states also support deterministic offscreen fixtures.
struct CaseAccessInteractionOverlay: View {
    let hovering: Bool
    let pressed: Bool
    let focused: Bool
    let enabled: Bool
    var cornerRadius: CGFloat = 7

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.white.opacity(enabled ? (pressed ? 0.16 : (hovering ? 0.09 : 0)) : 0))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(enabled && focused ? .white.opacity(0.9) : .clear, lineWidth: 1))
    }
}
