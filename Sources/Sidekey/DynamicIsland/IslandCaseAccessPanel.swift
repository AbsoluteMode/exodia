import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// «Доступ приложений»: registered apps with Approve / Bypass, optional
/// per-project modes, registration of known clients or any program, and the
/// minutes of «Разрешить на N мин». Mockup `case-ai-connect-v2`.
struct IslandCaseAccessPanel: View {
    @ObservedObject var viewModel: CaseViewModel
    var onBack: () -> Void

    /// Projects shown under an app with «как у приложения» before a mode is
    /// picked for them (overrides themselves live in the vault).
    @State private var shownProjects: [UUID: Set<UUID>]
    @State private var isPickingApp = false
    @State private var availableClients: [CaseKnownClient] = []
    @State private var isLoadingClients = false
    @State private var minutesDraft = ""
    @State private var lastError: String?
    @State private var isBusy = false
    @FocusState private var minutesFocused: Bool

    init(viewModel: CaseViewModel, onBack: @escaping () -> Void,
         initiallyShownProjects: [UUID: Set<UUID>] = [:]) {
        self.viewModel = viewModel
        self.onBack = onBack
        _shownProjects = State(initialValue: initiallyShownProjects)
    }

    static let title = "Доступ к ключам"
    static let explanation = "Approve — спрашивать. Bypass — без запроса."
    static let footer = "Подключение и Bypass — через Touch ID."
    static let sharedTerminalHint = "Bypass действует и для ваших команд в этом терминале."
    static let builtInSubtitle = "встроенный агент Whytap"
    static let inheritLabel = "как у приложения"

    var body: some View {
        VStack(spacing: 6) {
            header
            if let lastError {
                messageLine(lastError)
            }
            ForEach(viewModel.clientSetupProblems, id: \.self) { problem in
                messageLine(problem)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    Text(Self.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 5)
                    ForEach(viewModel.registrations) { app in
                        appCard(app)
                    }
                    registerSection
                    minutesRow
                    Text(Self.footer)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)
        .padding(.top, IslandCaseVaultStyle.topPadding)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { minutesDraft = String(viewModel.timedApprovalMinutes) }
        .onChange(of: minutesFocused) { _, focused in
            if !focused { commitMinutes() }
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text(Self.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            HStack {
                Button(action: onBack) {
                    Text("‹ Ключи")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("case.access.back")
                Spacer()
            }
        }
        .frame(height: 22)
    }

    private func messageLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: IslandCaseVaultStyle.errorFontSize, weight: .medium))
            .foregroundStyle(Color.red.opacity(0.8))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    // MARK: App card

    private func appCard(_ app: CaseAppRegistration) -> some View {
        let known = CaseKnownClient(identity: app.identity)
        let overrideIDs = projectRows(for: app)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(app.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                Spacer(minLength: 4)
                CaseModeSegment(
                    options: [.init(label: "Approve", value: .approve), .init(label: "Bypass", value: .bypass)],
                    selected: app.defaultMode,
                    identifierPrefix: "case.access.mode"
                ) { mode in
                    if let mode { perform { try await viewModel.setMode(mode, for: app.id, project: nil) } }
                }
                Button {
                    unregister(app)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: IslandCaseVaultStyle.iconButtonSize, height: IslandCaseVaultStyle.iconButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Удалить регистрацию — доступ закроется сразу")
                .accessibilityLabel("Удалить \(app.displayName)")
                .accessibilityIdentifier("case.access.unregister")
            }

            if app.identity == .builtInOpenCode {
                Text(Self.builtInSubtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
            }

            ForEach(overrideIDs, id: \.self) { projectID in
                projectRow(app: app, projectID: projectID)
            }

            addProjectMenu(app: app, shown: Set(overrideIDs))

            if Self.showsSharedTerminalHint(app: app, known: known) {
                Text(Self.sharedTerminalHint)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.81, blue: 0.48).opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    /// An editor whose terminal the person shares with its agent (Cursor or
    /// any program picked by path) shows the hint while Bypass is on anywhere.
    static func showsSharedTerminalHint(app: CaseAppRegistration, known: CaseKnownClient?) -> Bool {
        let shared: Bool
        if let known {
            shared = known.hasSharedTerminal
        } else if case .executablePath = app.identity {
            shared = true
        } else {
            shared = false
        }
        return shared && (app.defaultMode == .bypass || app.projectModes.values.contains(.bypass))
    }

    private func projectRows(for app: CaseAppRegistration) -> [UUID] {
        let ids = Set(app.projectModes.keys).union(shownProjects[app.id] ?? [])
        return viewModel.accessProjects.map(\.id).filter { ids.contains($0) }
    }

    private func projectRow(app: CaseAppRegistration, projectID: UUID) -> some View {
        let name = viewModel.accessProjects.first { $0.id == projectID }?.name ?? ""
        return HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            Spacer(minLength: 4)
            CaseModeSegment(
                options: [.init(label: Self.inheritLabel, value: nil),
                          .init(label: "Approve", value: .approve),
                          .init(label: "Bypass", value: .bypass)],
                selected: app.projectModes[projectID],
                identifierPrefix: "case.access.project",
                segmentPadding: 4
            ) { mode in
                perform { try await viewModel.setMode(mode, for: app.id, project: projectID) }
            }
        }
        .padding(.leading, 4)
    }

    private func addProjectMenu(app: CaseAppRegistration, shown: Set<UUID>) -> some View {
        let candidates = viewModel.accessProjects.filter { !shown.contains($0.id) }
        return Group {
            if !candidates.isEmpty {
                Menu {
                    ForEach(candidates) { project in
                        Button(project.name) {
                            shownProjects[app.id, default: []].insert(project.id)
                        }
                    }
                } label: {
                    Text("+ отдельно для проекта")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.leading, 4)
                .accessibilityIdentifier("case.access.addProject")
            }
        }
    }

    // MARK: Registration

    private var registerSection: some View {
        VStack(spacing: 4) {
            Button {
                isPickingApp.toggle()
                if isPickingApp { loadClients() }
            } label: {
                Text("+ Зарегистрировать приложение")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityIdentifier("case.access.register")

            if isPickingApp {
                VStack(spacing: 3) {
                    if isLoadingClients {
                        pickerRow(title: "Ищу приложения…", systemImage: "hourglass", enabled: false) {}
                    }
                    ForEach(availableClients, id: \.self) { client in
                        pickerRow(title: client == .builtInOpenCode
                                  ? "\(client.displayName) — \(Self.builtInSubtitle)" : client.displayName,
                                  systemImage: "plus.circle", enabled: !isBusy) {
                            register(client.identity, name: client.displayName)
                        }
                    }
                    pickerRow(title: "Выбрать программу…", systemImage: "folder", enabled: !isBusy) {
                        chooseProgram()
                    }
                }
            }
        }
    }

    private func pickerRow(title: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.4))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Minutes

    private var minutesRow: some View {
        HStack(spacing: 5) {
            Text("Разрешение на")
            TextField("", text: $minutesDraft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .frame(width: 34, height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.10)))
                .focused($minutesFocused)
                .onSubmit(commitMinutes)
                .accessibilityIdentifier("case.access.minutes")
            Text("мин")
            Spacer(minLength: 0)
            Text("1–240")
                .foregroundStyle(.white.opacity(0.35))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 2)
    }

    private func commitMinutes() {
        guard let minutes = CaseViewModel.parseTimedMinutes(minutesDraft) else {
            lastError = "Разрешение: от 1 до 240 минут"
            minutesDraft = String(viewModel.timedApprovalMinutes)
            return
        }
        guard minutes != viewModel.timedApprovalMinutes else { return }
        do {
            try viewModel.setTimedApprovalMinutes(minutes)
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
            minutesDraft = String(viewModel.timedApprovalMinutes)
        }
    }

    // MARK: Actions

    private func loadClients() {
        isLoadingClients = true
        Task { @MainActor in
            availableClients = await viewModel.availableClientsToRegister()
            isLoadingClients = false
        }
    }

    private func register(_ identity: CaseAppIdentity, name: String) {
        perform {
            _ = try await viewModel.registerApp(identity, name: name)
            isPickingApp = false
        }
    }

    private func unregister(_ app: CaseAppRegistration) {
        shownProjects[app.id] = nil
        perform { _ = try await viewModel.unregisterApp(app.id) }
    }

    private func chooseProgram() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Зарегистрировать"
        panel.message = "Программа, которой можно давать ключи Case"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let choice = Self.programChoice(for: url) else { return }
            register(choice.identity, name: choice.name)
        }
    }

    /// An app bundle or an executable file, matched by its resolved path.
    static func programChoice(for url: URL) -> (identity: CaseAppIdentity, name: String)? {
        let resolved = url.resolvingSymlinksInPath()
        let isApp = resolved.pathExtension == "app"
        guard isApp || FileManager.default.isExecutableFile(atPath: resolved.path) else { return nil }
        let identity = CaseAppIdentity.executablePath(resolved.path)
        if let known = CaseKnownClient(identity: identity) {
            return (known.identity, known.displayName)
        }
        let name = isApp ? resolved.deletingPathExtension().lastPathComponent : resolved.lastPathComponent
        return (identity, name)
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await work()
                lastError = nil
            } catch {
                lastError = Self.message(for: error)
            }
        }
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
