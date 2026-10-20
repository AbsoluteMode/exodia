import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum IslandCaseVaultStyle {
    static let horizontalPadding: CGFloat = 10
    static let topPadding: CGFloat = 8
    static let rowSpacing: CGFloat = 5
    static let inputHeight: CGFloat = 28
    static let rowHeight: CGFloat = 26
    static let childRowHeight: CGFloat = 24
    static let iconButtonSize: CGFloat = 18
    static let inputFontSize: CGFloat = 11
    static let nameFontSize: CGFloat = 10
    static let errorFontSize: CGFloat = 9
    static let descriptionFontSize: CGFloat = 9
    static let rowCornerRadius: CGFloat = 9
    static let childIndent: CGFloat = 12
}

struct IslandCaseVaultPanel: View {
    @ObservedObject var viewModel: CaseViewModel

    /// The «ИИ … / Подключить ›» row opens «Доступ приложений» in place.
    static let isAccessScreenAvailable = true

    /// While searching every matching project is shown expanded.
    static func isExpanded(_ section: CaseProjectSection, expandedIDs: Set<UUID>, isSearching: Bool) -> Bool {
        isSearching || expandedIDs.contains(section.id)
    }

    var onOpenAccessScreen: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var valueDraft = ""
    @State private var editSecretID: UUID?
    @State private var editName = ""
    @State private var editValue = ""
    @State private var editDescription = ""
    @State private var addingProjectID: UUID?
    @State private var projectEditor: ProjectEditor?
    @State private var projectNameDraft = ""
    @State private var projectDescriptionDraft = ""
    @State private var pendingDeleteProjectID: UUID?
    @State private var dragState = CaseDragState()
    @State private var lastError: String?
    @State private var showingAccess = false
    @FocusState private var inputFocused: Bool

    private let topScrollID = "case-list-top"
    private let bottomScrollID = "case-list-bottom"
    @State private var isUnlocking = false
    @State private var hasTriggeredInitialUnlock = false

    var body: some View {
        Group {
            if viewModel.isUnlocked {
                if showingAccess {
                    IslandCaseAccessPanel(viewModel: viewModel, onBack: {
                        viewModel.dismissClientSetupProblems()
                        showingAccess = false
                    })
                } else {
                    unlockedPanel
                }
            } else {
                lockedPanel
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                inputFocused = true
            }
            // Clear any stale armed-reset state from a previous panel open so
            // the user always starts the two-step confirm fresh.
            viewModel.disarmResetVault()
            unlockIfNeededOnOpen()
        }
    }

    private var lockedPanel: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 6)

            if case let .needsReset(message) = viewModel.unlockState {
                Button(action: resetCase) {
                    unlockPill(title: viewModel.isResetArmed ? "Подтвердить сброс" : "Сбросить Case")
                }
                .buttonStyle(.plain)
                .disabled(isUnlocking)

                // Armed: spell out the stakes — the second press is irreversible.
                Text(viewModel.isResetArmed
                    ? "Case будет удалён навсегда. Нажмите ещё раз для подтверждения."
                    : message)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
            } else if case let .needsNewerApp(message) = viewModel.unlockState {
                unlockPill(title: "Нужно обновление")

                Text(message)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
            } else {
                if isUnlocking || !hasTriggeredInitialUnlock {
                    unlockPill(title: "Открываю…")
                } else {
                    Button(action: unlock) {
                        unlockPill(title: "Открыть ещё раз")
                    }
                    .buttonStyle(.plain)
                    .disabled(isUnlocking)
                }

                Text("Touch ID или пароль macOS")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))

                if case let .failed(message) = viewModel.unlockState {
                    Text(message)
                        .font(.system(size: IslandCaseVaultStyle.errorFontSize, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, 14)
                }
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unlockPill(title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.open")
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.94))
        .padding(.horizontal, 13)
        .frame(height: 30)
        .background(Capsule().fill(Color.white.opacity(0.14)))
        .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 0.8))
    }

    private var unlockedPanel: some View {
        VStack(spacing: IslandCaseVaultStyle.rowSpacing) {
            inputBar
                .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)
                .padding(.top, IslandCaseVaultStyle.topPadding)

            if projectEditor == .create {
                projectEditorControls(isGeneral: false)
                    .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)
            }

            if let lastError {
                Text(lastError)
                    .font(.system(size: IslandCaseVaultStyle.errorFontSize, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding + 2)
            }

            caseList
                .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)

            if Self.isAccessScreenAvailable {
                accessRow
                    .padding(.horizontal, IslandCaseVaultStyle.horizontalPadding)
            }
        }
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if activeInputText.isEmpty {
                    Text(inputPlaceholder)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .allowsHitTesting(false)
                }

                inputField
                    .font(.system(size: IslandCaseVaultStyle.inputFontSize, weight: .medium))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 10)
                    .focused($inputFocused)
                    .onSubmit(submitInput)
            }
            .frame(height: IslandCaseVaultStyle.inputHeight)
            .background(Capsule().fill(Color.white.opacity(0.13)))
            .overlay(Capsule().stroke(inputBorderColor, lineWidth: 0.8))

            if viewModel.inputMode != .name || addingProjectID != nil {
                IslandCaseIconButton(action: Self.cancelInputAction) {
                    valueDraft = ""
                    addingProjectID = nil
                    viewModel.cancelInput()
                    lastError = nil
                }
            }

            Button(action: startCreatingProject) {
                Text("+ Проект")
                    .font(.system(size: IslandCaseVaultStyle.nameFontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .frame(height: IslandCaseVaultStyle.inputHeight)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.7))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("case.project.create")
        }
    }

    private static let cancelInputAction = IslandCaseRowAction(
        systemImage: "xmark",
        accessibilityIdentifier: "case.input.cancel",
        accessibilityLabel: "Отменить ввод ключа"
    )

    @ViewBuilder
    private var inputField: some View {
        switch viewModel.inputMode {
        case .name:
            TextField("", text: $viewModel.query)
        case .value:
            SecureField("", text: $valueDraft)
        }
    }

    private var activeInputText: String {
        switch viewModel.inputMode {
        case .name:
            return viewModel.query
        case .value:
            return valueDraft
        }
    }

    private var inputPlaceholder: String {
        switch viewModel.inputMode {
        case .name:
            if let addingProjectID {
                let name = viewModel.projectSections.first { $0.id == addingProjectID }?.name
                    ?? CaseProject.generalName
                return "Новый ключ в \(name)"
            }
            return "Имя ключа или поиск"
        case .value:
            return "Введите значение"
        }
    }

    private var inputBorderColor: Color {
        lastError == nil ? Color.white.opacity(0.18) : Color.red.opacity(0.60)
    }

    private var caseList: some View {
        let sections = viewModel.projectSections
        let searching = viewModel.isSearching
        return ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        Color.clear.frame(height: 1).id(topScrollID)

                        ForEach(sections) { section in
                            projectSection(
                                section,
                                isExpanded: Self.isExpanded(section, expandedIDs: viewModel.expandedProjectIDs, isSearching: searching)
                            )
                        }

                        Color.clear.frame(height: 1).id(bottomScrollID)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onContinuousHover { phase in
                    // Never reset here: the pointer can leave and re-enter mid-drag.
                    if case let .active(location) = phase {
                        scrollIfNeeded(
                            pointerY: location.y,
                            viewportHeight: geometry.size.height,
                            proxy: proxy
                        )
                    }
                }
                // A drag released on empty list space (or cancelled) never reaches a
                // project row's drop handler; clear it here so auto-scroll stops.
                .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                    dragState.reset()
                    return false
                }
                .onDisappear { dragState.reset() }
            }
        }
    }

    @ViewBuilder
    private func projectSection(_ section: CaseProjectSection, isExpanded: Bool) -> some View {
        IslandCaseProjectRow(
            section: section,
            isExpanded: isExpanded,
            isDropTargeted: dragState.dropTargetProjectID == section.id,
            onToggle: { toggleProject(section.id) },
            onEdit: { startEditingProject(section) },
            onDelete: {
                pendingDeleteProjectID = pendingDeleteProjectID == section.id ? nil : section.id
                lastError = nil
            }
        )
        .onDrop(of: [UTType.text], isTargeted: dropTargetBinding(section.id)) { _ in
            handleDrop(onProject: section.id)
        }

        if pendingDeleteProjectID == section.id, !section.isGeneral {
            IslandCaseProjectDeleteConfirmation(
                name: section.name,
                keyCount: section.keyCount,
                onConfirm: { confirmDeleteProject(section.id) },
                onCancel: { pendingDeleteProjectID = nil }
            )
        }

        if projectEditor == .edit(section.id) {
            projectEditorControls(isGeneral: section.isGeneral)
        }

        if isExpanded {
            ForEach(section.secrets) { secret in
                VStack(spacing: 3) {
                    IslandCaseSecretRow(
                        row: secret,
                        onEdit: { startEditingSecret(secret) },
                        onCopy: { runCaseAction { try viewModel.copySecret(secret.id) } },
                        onDelete: { runCaseAction { try viewModel.deleteSecret(secret.id) } }
                    )
                    .onDrag {
                        dragState.begin(secretID: secret.id, sourceProjectID: secret.projectID)
                        return NSItemProvider(object: secret.id.uuidString as NSString)
                    }
                    .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                        handleDrop(onProject: secret.projectID)
                    }

                    if editSecretID == secret.id {
                        secretEditControls(secret)
                    }
                }
                .padding(.leading, IslandCaseVaultStyle.childIndent)
            }

            IslandCaseAddKeyRow(projectName: section.name) {
                startAddingKey(to: section.id)
            }
            .padding(.leading, IslandCaseVaultStyle.childIndent)
        }
    }

    private func secretEditControls(_ row: CaseDisplayRow) -> some View {
        VStack(spacing: 4) {
            editField {
                TextField("Имя", text: $editName)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            }
            editField {
                SecureField("Новое значение", text: $editValue)
                    .font(.system(size: 9.5, weight: .medium))
                    .onSubmit { saveSecretEdit(row) }
            }
            editField {
                TextField("Описание", text: $editDescription)
                    .font(.system(size: 9.5, weight: .medium))
                    .onSubmit { saveSecretEdit(row) }
            }
            editButtons(
                onSave: { saveSecretEdit(row) },
                onCancel: {
                    editSecretID = nil
                    editValue = ""
                    lastError = nil
                }
            )
        }
        .padding(.leading, 6)
    }

    private func projectEditorControls(isGeneral: Bool) -> some View {
        VStack(spacing: 4) {
            if !isGeneral {
                editField {
                    TextField("Название проекта", text: $projectNameDraft)
                        .font(.system(size: 9.5, weight: .medium))
                        .onSubmit(saveProjectEditor)
                }
            }
            editField {
                TextField("Описание", text: $projectDescriptionDraft)
                    .font(.system(size: 9.5, weight: .medium))
                    .onSubmit(saveProjectEditor)
            }
            editButtons(
                onSave: saveProjectEditor,
                onCancel: {
                    projectEditor = nil
                    lastError = nil
                }
            )
        }
    }

    private func editField<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .textFieldStyle(.plain)
            .foregroundStyle(.white.opacity(0.90))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(0.10)))
    }

    private func editButtons(onSave: @escaping () -> Void, onCancel: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            IslandCaseIconButton(action: Self.cancelEditAction, perform: onCancel)
            IslandCaseIconButton(action: Self.saveEditAction, perform: onSave)
        }
    }

    private static let saveEditAction = IslandCaseRowAction(
        systemImage: "checkmark",
        accessibilityIdentifier: "case.edit.save",
        accessibilityLabel: "Сохранить"
    )

    private static let cancelEditAction = IslandCaseRowAction(
        systemImage: "xmark",
        accessibilityIdentifier: "case.edit.cancel",
        accessibilityLabel: "Отменить правку"
    )

    private var accessRow: some View {
        let names = viewModel.registeredAppNames
        return HStack(spacing: 6) {
            Circle()
                .fill(names.isEmpty ? Color.white.opacity(0.30) : Color.green.opacity(0.85))
                .frame(width: 6, height: 6)
            Text(names.isEmpty ? "ИИ: нет" : "ИИ: \(names.joined(separator: ", "))")
                .font(.system(size: IslandCaseVaultStyle.nameFontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Spacer(minLength: 4)
            Button {
                showingAccess = true
                onOpenAccessScreen?()
            } label: {
                Text("Подключить ›")
                    .font(.system(size: IslandCaseVaultStyle.nameFontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("case.access.open")
        }
        .padding(.top, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5)
        }
    }

    private func unlock() {
        guard !isUnlocking else { return }
        hasTriggeredInitialUnlock = true
        isUnlocking = true
        Task { @MainActor in
            defer { isUnlocking = false }
            do {
                try await viewModel.unlock()
                lastError = nil
                inputFocused = true
            } catch {
                lastError = nil
            }
        }
    }

    private func unlockIfNeededOnOpen() {
        guard !viewModel.isUnlocked, !hasTriggeredInitialUnlock else {
            return
        }
        unlock()
    }

    private func resetCase() {
        guard !isUnlocking else { return }
        // Two-step confirm: first press arms (button label flips to "Confirm
        // Reset"), second press executes. armResetVault() returns true when it
        // arms; false if already armed -> proceed to the actual reset.
        let justArmed = viewModel.armResetVault()
        if justArmed {
            // Armed — wait for the second press. Nothing destructive yet.
            return
        }
        do {
            try viewModel.resetVault()
        } catch {
            // Reset failed (e.g. file removal error) — keep the needsReset
            // state so the user can retry; nothing sensitive to surface.
            return
        }
        unlock()
    }

    private func submitInput() {
        do {
            switch viewModel.inputMode {
            case .name:
                try viewModel.submitName(viewModel.query, projectID: addingProjectID ?? CaseProject.generalID)
                valueDraft = ""
                // Name accepted -> inputMode flips to .value and the field
                // rebuilds as a SecureField. Re-assert focus on the next runloop
                // tick so the cursor lands in the value field without a click.
                DispatchQueue.main.async { inputFocused = true }
            case .value:
                try viewModel.submitValue(valueDraft)
                valueDraft = ""
                addingProjectID = nil
            }
            lastError = nil
        } catch {
            lastError = caseErrorMessage(for: error)
        }
    }

    private func startAddingKey(to projectID: UUID) {
        addingProjectID = projectID
        valueDraft = ""
        viewModel.cancelInput()
        lastError = nil
        inputFocused = true
    }

    private func startEditingSecret(_ row: CaseDisplayRow) {
        editSecretID = editSecretID == row.id ? nil : row.id
        editName = row.displayName
        editValue = ""
        editDescription = row.description
        lastError = nil
    }

    private func saveSecretEdit(_ row: CaseDisplayRow) {
        runCaseAction {
            if editValue.isEmpty {
                if editName != row.displayName {
                    try viewModel.renameSecret(row.id, rawName: editName)
                }
            } else {
                try viewModel.replaceSecret(row.id, rawName: editName, newValue: editValue)
            }
            if editDescription != row.description {
                try viewModel.setSecretDescription(row.id, editDescription)
            }
            editSecretID = nil
            editValue = ""
        }
    }

    private func startCreatingProject() {
        if projectEditor == .create {
            projectEditor = nil
            return
        }
        projectEditor = .create
        projectNameDraft = ""
        projectDescriptionDraft = ""
        pendingDeleteProjectID = nil
        lastError = nil
    }

    private func startEditingProject(_ section: CaseProjectSection) {
        if projectEditor == .edit(section.id) {
            projectEditor = nil
            return
        }
        projectEditor = .edit(section.id)
        projectNameDraft = section.name
        projectDescriptionDraft = section.description
        pendingDeleteProjectID = nil
        lastError = nil
    }

    private func saveProjectEditor() {
        guard let projectEditor else { return }
        runCaseAction(isProjectAction: true) {
            switch projectEditor {
            case .create:
                try viewModel.createProject(name: projectNameDraft, description: projectDescriptionDraft)
            case let .edit(projectID):
                let current = viewModel.projectSections.first { $0.id == projectID }
                if projectID != CaseProject.generalID, projectNameDraft != current?.name {
                    try viewModel.renameProject(projectID, name: projectNameDraft)
                }
                if projectDescriptionDraft != current?.description {
                    try viewModel.setProjectDescription(projectID, projectDescriptionDraft)
                }
            }
            self.projectEditor = nil
        }
    }

    private func confirmDeleteProject(_ projectID: UUID) {
        runCaseAction {
            try viewModel.deleteProject(projectID)
            pendingDeleteProjectID = nil
            if addingProjectID == projectID {
                addingProjectID = nil
            }
        }
    }

    private func dropTargetBinding(_ projectID: UUID) -> Binding<Bool> {
        Binding(
            get: { dragState.dropTargetProjectID == projectID },
            set: { targeted in
                if targeted {
                    dragState.dropTargetProjectID = projectID
                } else if dragState.dropTargetProjectID == projectID {
                    dragState.dropTargetProjectID = nil
                }
            }
        )
    }

    /// Dropping a dragged key on a project header (or on one of its keys)
    /// moves the key into that project. A name clash there is refused.
    private func handleDrop(onProject projectID: UUID) -> Bool {
        let context = dragState.context
        defer { dragState.reset() }
        guard let dragContext = context, dragContext.sourceProjectID != projectID else {
            return false
        }
        runCaseAction {
            try viewModel.moveSecret(dragContext.secretID, toProject: projectID)
            viewModel.expandedProjectIDs.insert(projectID)
        }
        return true
    }

    private func scrollIfNeeded(
        pointerY: CGFloat,
        viewportHeight: CGFloat,
        proxy: ScrollViewProxy
    ) {
        let velocity = dragState.scrollVelocity(
            pointerY: pointerY,
            viewportHeight: viewportHeight
        )
        guard velocity != 0 else {
            return
        }

        withAnimation(reduceMotion ? nil : .linear(duration: 0.12)) {
            proxy.scrollTo(velocity < 0 ? topScrollID : bottomScrollID, anchor: velocity < 0 ? .top : .bottom)
        }
    }

    private func toggleProject(_ projectID: UUID) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            if viewModel.expandedProjectIDs.contains(projectID) {
                viewModel.expandedProjectIDs.remove(projectID)
            } else {
                viewModel.expandedProjectIDs.insert(projectID)
            }
        }
    }

    private func runCaseAction(isProjectAction: Bool = false, _ action: () throws -> Void) {
        do {
            try action()
            lastError = nil
        } catch {
            lastError = caseErrorMessage(for: error, isProjectAction: isProjectAction)
        }
    }

    private func caseErrorMessage(for error: Error, isProjectAction: Bool = false) -> String {
        switch error {
        case CaseNameValidationError.empty:
            return "Введите имя"
        case CaseNameValidationError.rawTooLong:
            return "Имя слишком длинное"
        case CaseNameValidationError.nonASCII:
            return "Только A-Z, 0-9 и разделители"
        case CaseNameValidationError.normalizedTooLong:
            return "Имя после приведения слишком длинное"
        case CaseViewModelError.duplicateName:
            return isProjectAction ? "Такой проект уже есть" : "Такой ключ уже есть"
        case CaseViewModelError.emptyValue:
            return "Введите значение"
        case CaseViewModelError.valueTooLong:
            return "Значение слишком длинное"
        case CaseViewModelError.invalidProjectName:
            return "Недопустимое имя проекта"
        case CaseViewModelError.invalidProjectOperation:
            return "Этот проект нельзя изменить"
        case CaseViewModelError.descriptionTooLong:
            return "Описание слишком длинное"
        case CaseViewModelError.missingProject:
            return "Проект не найден"
        case CaseViewModelError.locked:
            return "Case заблокирован"
        default:
            return "Не получилось"
        }
    }
}

private enum ProjectEditor: Equatable {
    case create
    case edit(UUID)
}
