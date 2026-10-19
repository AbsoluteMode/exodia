import AppKit
import SwiftUI

@MainActor
struct SettingsBackupView: View {
    @ObservedObject var model: BackupViewModel = .shared

    // Flow navigation state
    @State private var isSetupActive = false
    @State private var isRestoreActive = false
    @State private var localRecoveryVerified = false

    // Setup inputs
    @State private var isGeneratedCodeRevealed = true
    @State private var verifyCodeInput = ""
    @State private var isVerifyCodeRevealed = false
    @State private var verifyErrorMessage: String?
    @State private var setupTokenInput = ""
    @State private var isSetupTokenRevealed = false
    @State private var showSetupTokenEntry = false

    // Configured state recovery code reveal
    @State private var isConfiguredCodeRevealed = false

    // Restore inputs
    @State private var restoreCodeInput = ""
    @State private var isRestoreCodeRevealed = false
    @State private var restoreTokenInput = ""
    @State private var isRestoreTokenRevealed = false
    @State private var showRestoreConnectionOptions = false
    @State private var excludedRestoreSections: Set<ArtifactBackupSection> = []

    // Local settings history state
    @State private var selectedConfigSection: ConfigBackupSection = .models
    @State private var selectedSnapshotID: UUID?
    @State private var pendingSectionRestore: PendingSectionRestore?
    @State private var showDefaultsConfirmation = false
    @State private var shownVersionCount = 20
    @State private var activationItem: ArtifactParkedItem?

    private struct PendingSectionRestore: Equatable {
        let section: ConfigBackupSection
        let snapshot: ConfigBackupSnapshot
    }

    private var isConfigured: Bool {
        model.isEnabled ||
        model.lastBackupAt != nil ||
        model.lastRemoteBackupAt != nil ||
        (model.recoverySaved && !model.destinationName.isEmpty && model.destinationName != "Not connected")
    }

    private var hasRestoreOnlyConnection: Bool {
        !isConfigured && !model.destinationName.isEmpty && model.destinationName != "Not connected"
    }

    private var isShowingSetup: Bool {
        !model.isEnabled && (isSetupActive || (!isConfigured && !model.recoveryCode.isEmpty))
    }

    private var isSetupCodeVerified: Bool {
        model.recoverySaved || localRecoveryVerified
    }

    private var isFolderDestination: Bool {
        let lower = model.destinationName.lowercased()
        if lower.hasPrefix("github") { return false }
        return lower.hasPrefix("folder") || lower.contains("icloud") || lower.contains("dropbox") || lower.contains("drive")
    }

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection

                if model.needsRestart { needsRestartBanner }
                if let notice = model.restoreNotice { restoreOutcomeCard(notice) }
                if model.recoveryCheckpoint != nil || !model.parkedItems.isEmpty { recoveryFilesCard }

                if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
                    errorBanner(errorMessage)
                }

                if let preview = model.restorePreview {
                    restorePreviewSection(preview)
                } else if isShowingSetup {
                    setupSection
                } else if isConfigured {
                    configuredSection
                    restoreBrowserSection(isNewMacMode: false)
                } else {
                    emptyStateSection
                    if isRestoreActive || hasRestoreOnlyConnection || !model.versions.isEmpty {
                        restoreBrowserSection(isNewMacMode: true)
                    }
                }

                localSettingsHistorySection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: showRestoreConnectionOptions) { _, shown in
            if shown { withAnimation { scroll.scrollTo("backup-restore", anchor: .top) } }
        }
        .onChange(of: isRestoreActive) { _, shown in
            if shown { withAnimation { scroll.scrollTo("backup-restore", anchor: .top) } }
        }
        }
        .focusable(false)
        .onChange(of: model.isEnabled) { _, enabled in
            if enabled { isSetupActive = false; model.hideRecoveryCode() }
        }
        .onDisappear { clearSensitiveInput() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window.title.contains("Settings") { clearSensitiveInput() }
        }
        .alert("Restore app defaults for \(selectedConfigSection.title)?", isPresented: $showDefaultsConfirmation) {
            Button("Restore defaults") { Task { await model.restoreSettingsDefaults(selectedConfigSection) } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only this settings block will return to the app defaults at the next normal launch. A copy of its current values is kept. Provider keys are kept.")
        }
    }

    private func clearSensitiveInput() {
        model.hideRecoveryCode()
        verifyCodeInput = ""; setupTokenInput = ""; restoreTokenInput = ""; restoreCodeInput = ""
        isConfiguredCodeRevealed = false; isSetupActive = false
        isGeneratedCodeRevealed = false; isVerifyCodeRevealed = false
        isSetupTokenRevealed = false; isRestoreCodeRevealed = false; isRestoreTokenRevealed = false
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Backup")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                Text(model.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.isBusy {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Working…")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.text2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Backup operation in progress")
                if model.canCancelOperation {
                    MacButton(title: "Cancel", style: .default) { model.cancelCurrentOperation() }
                }
            }
        }
    }

    // MARK: - Top Banners (Restart & Error)

    private var needsRestartBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacBanner(tone: .info, systemImage: "arrow.clockwise.circle",
                title: "Ready for your next launch",
                text: "Quit Whytap normally and open it again when your work is finished. Your previous data is kept for recovery.")
            MacButton(title: "Cancel planned restore", style: .default, isEnabled: !model.isBusy) {
                model.cancelPlannedRestore()
            }
        }
    }

    private func restoreOutcomeCard(_ outcome: ArtifactRestoreOutcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MacBanner(tone: outcome.state == .applied ? .info : .warn,
                systemImage: outcome.state == .applied ? "checkmark.circle" : "exclamationmark.triangle",
                title: outcome.message, text: outcome.warnings.joined(separator: " "))
            MacButton(title: "Dismiss", style: .default) { model.dismissRestoreNotice() }
        }
    }

    private var recoveryFilesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Recovered data")
            MacCard {
                if let checkpoint = model.recoveryCheckpoint {
                    MacRow(title: "Previous data on this Mac", subtitle: "All restore checkpoints are kept in this folder. Latest: \(Self.formatDate(checkpoint.createdAt, emptyText: "saved date")).") {
                        MacButton(title: "Show all copies…", style: .default) { model.showRecoveryFiles() }
                    }
                }
                ForEach(model.parkedItems) { item in
                    MacRowSeparator()
                    MacRow(title: item.title, subtitle: item.kind == .stagedRecording ? "Audio is kept. Processing waits for your decision." : "Your connections are kept and remain switched off.") {
                        MacButton(title: "Show files…", style: .default) { model.showParkedFiles(item) }
                        MacButton(title: item.kind == .stagedRecording ? "Allow processing…" : "Enable connections…", style: .tinted,
                                  isEnabled: !model.isBusy && !model.needsRestart) { activationItem = item }
                    }
                }
            }
        }
        .confirmationDialog("Enable this recovered configuration?", isPresented: Binding(
            get: { activationItem != nil }, set: { if !$0 { activationItem = nil } }), titleVisibility: .visible) {
                Button("Enable") { if let item = activationItem { model.activateRecoveredItem(item) }; activationItem = nil }
                Button("Cancel", role: .cancel) { activationItem = nil }
        } message: {
            Text("Connections may contact your configured servers. A recording may be sent to your selected speech and text providers using your keys. Enabling allows Whytap to use this recovered item when it next checks for work.")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MacSettingsTheme.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Backup needs attention")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if isConfigured && model.isEnabled {
                        MacButton(
                            title: "Retry backup",
                            style: .primary,
                            isEnabled: !model.isBusy && !model.needsRestart
                        ) {
                            Task { await model.backupNow() }
                        }
                        .accessibilityLabel("Retry backup now")
                    }
                    MacButton(
                        title: "Dismiss",
                        style: .default,
                        isEnabled: true
                    ) {
                        model.clearError()
                    }
                    .accessibilityLabel("Dismiss backup error")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous)
                    .fill(MacSettingsTheme.bgCard)
                RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous)
                    .fill(MacSettingsTheme.orange.opacity(0.12))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous)
                .strokeBorder(MacSettingsTheme.orange.opacity(0.38), lineWidth: 0.75)
        )
    }

    // MARK: - Main Empty State

    private var emptyStateSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Encrypted Backup", trailing: "No Whytap account")
            MacCard {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keep a safe copy")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MacSettingsTheme.text)
                        Text("Settings, provider keys, Case, meetings and saved attachments. Encrypted before they leave your Mac.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(MacSettingsTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        MacButton(
                            title: "Set up backup",
                            style: .primary,
                            isEnabled: !model.isBusy && !model.needsRestart
                        ) {
                            verifyErrorMessage = nil
                            verifyCodeInput = ""
                            localRecoveryVerified = false
                            isRestoreActive = false
                            isSetupActive = true
                            model.beginSetup()
                        }
                        .accessibilityLabel("Set up backup")

                        MacButton(
                            title: "Restore a backup",
                            style: .default,
                            isEnabled: !model.isBusy && !model.needsRestart
                        ) {
                            isSetupActive = false
                            isRestoreActive = true
                            showRestoreConnectionOptions = true
                            Task { await model.refreshVersions() }
                        }
                        .accessibilityLabel("Restore a backup without existing setup")

                        Spacer()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)

                MacRowSeparator()

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .padding(.top, 1)
                    Text("Clipboard file links keep paths to external originals. Those original files are not copied. Your saved images and app-owned attachments are included.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Setup Flow (Step 1: Recovery Code, Step 2: Connect Destination)

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(
                title: "Set Up Backup",
                trailing: isSetupCodeVerified ? "Step 2 of 2 · Connect destination" : "Step 1 of 2 · Recovery code"
            )
            MacCard {
                if !isSetupCodeVerified {
                    setupRecoveryCodeStep
                } else {
                    setupConnectDestinationStep
                }
            }
        }
    }

    private var setupRecoveryCodeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Save your recovery code once")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                    MacPill(text: "Save outside this Mac", tone: .neutral, showsDot: false)
                    Spacer()
                    MacButton(
                        title: isGeneratedCodeRevealed ? "Hide" : "Reveal",
                        style: .default
                    ) {
                        isGeneratedCodeRevealed.toggle()
                    }
                    .accessibilityLabel(isGeneratedCodeRevealed ? "Hide generated recovery code" : "Reveal generated recovery code")

                    MacButton(
                        title: "Copy to password manager",
                        style: .tinted,
                        isEnabled: !model.isBusy && !model.needsRestart
                    ) {
                        model.copyRecoveryCode()
                    }
                    .accessibilityLabel("Copy recovery code to password manager")
                }

                Text("Save this random recovery code in your password manager. Your archive is encrypted on this Mac before upload — GitHub cannot decrypt your backup or recover this code if you lose it.")
                    .font(.system(size: 12))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(displayedSetupRecoveryCode)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(MacSettingsTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Generated recovery code")
                    .accessibilityValue(isGeneratedCodeRevealed ? "Visible" : "Hidden")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            MacRowSeparator()

            VStack(alignment: .leading, spacing: 9) {
                Text("Verify your saved recovery code")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text)
                Text("Paste the saved recovery code back below to verify you can unlock backups on a new Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.text2)

                HStack(spacing: 8) {
                    MacField(
                        placeholder: "Paste saved recovery code (all 9 groups)",
                        text: $verifyCodeInput,
                        isSecure: !isVerifyCodeRevealed,
                        monospaced: true
                    )
                    .accessibilityLabel("Paste saved recovery code to verify")
                    .onSubmit {
                        confirmSetupCode()
                    }

                    MacButton(
                        title: isVerifyCodeRevealed ? "Hide" : "Show",
                        style: .ghost
                    ) {
                        isVerifyCodeRevealed.toggle()
                    }
                    .accessibilityLabel(isVerifyCodeRevealed ? "Hide verification input" : "Show verification input")

                    MacButton(
                        title: "Verify code",
                        style: .primary,
                        isEnabled: !model.isBusy && !model.needsRestart && !verifyCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        confirmSetupCode()
                    }
                    .accessibilityLabel("Verify recovery code")
                }

                if let verifyErrorMessage {
                    Text(verifyErrorMessage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.red)
                }

                HStack {
                    MacButton(title: "Cancel", style: .default) {
                        isSetupActive = false
                        model.hideRecoveryCode()
                        verifyCodeInput = ""
                        verifyErrorMessage = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var displayedSetupRecoveryCode: String {
        guard isGeneratedCodeRevealed else {
            return "••••••••-••••••••-••••••••-••••••••-••••••••-••••••••-••••••••-••••••••-••••••••"
        }
        return model.recoveryCode.isEmpty
            ? "XXXX-XXXX-XXXX-XXXX (Click Set up backup to generate)"
            : model.recoveryCode
    }

    private func confirmSetupCode() {
        let trimmed = verifyCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            verifyErrorMessage = ConfigBackupError.invalidCode.errorDescription
            return
        }
        do {
            try model.confirmRecoveryCode(trimmed)
            verifyErrorMessage = nil
            localRecoveryVerified = true
        } catch {
            verifyErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var setupConnectDestinationStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacRow(
                title: "Recovery code verified",
                subtitle: "Choose where Whytap should store your encrypted backup archives."
            ) {
                MacPill(text: "Verified", tone: .green, showsDot: true)
            }

            if isConfigured {
                MacRowSeparator()
                MacRow(title: model.destinationName, subtitle: "Use your connected destination for automatic encrypted backups.") {
                    MacButton(title: "Use this destination", style: .primary, isEnabled: !model.isBusy) {
                        model.setEnabled(true)
                        isSetupActive = false
                        Task { await model.backupNow() }
                    }
                }
            }
            MacRowSeparator()

            MacRow(
                title: "GitHub CLI (Recommended)",
                subtitle: "Uses your existing gh login on this Mac to connect or create a private backup repository."
            ) {
                MacButton(
                    title: "Connect GitHub CLI",
                    style: .primary,
                    isEnabled: !model.isBusy && !model.needsRestart
                ) {
                    Task { await model.connectExistingGitHub() }
                }
                .accessibilityLabel("Connect using existing GitHub CLI login")
            }

            MacRowSeparator()

            DisclosureGroup("Use an access token", isExpanded: $showSetupTokenEntry) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GitHub Personal Access Token")
                            .font(.system(size: 13))
                            .foregroundStyle(MacSettingsTheme.text)
                        Text("For an existing private Exodia-Backup repository, grant Contents read and write access. Creating it also requires Administration read and write access. Keep this token separate from your recovery code.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    MacField(
                        placeholder: "Fine-grained GitHub token (github_pat_...)",
                        text: $setupTokenInput,
                        isSecure: !isSetupTokenRevealed,
                        monospaced: true
                    )
                    .accessibilityLabel("GitHub Personal Access Token")
                    .onSubmit {
                        submitSetupGitHubToken()
                    }

                    MacButton(
                        title: isSetupTokenRevealed ? "Hide" : "Show",
                        style: .ghost
                    ) {
                        isSetupTokenRevealed.toggle()
                    }
                    .accessibilityLabel(isSetupTokenRevealed ? "Hide GitHub token" : "Show GitHub token")

                    MacButton(
                        title: "Connect token",
                        style: .tinted,
                        isEnabled: !model.isBusy && !model.needsRestart && !setupTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        submitSetupGitHubToken()
                    }
                    .accessibilityLabel("Connect GitHub with Personal Access Token")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            }
            .foregroundStyle(MacSettingsTheme.text2)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            MacRowSeparator()

            MacRow(
                title: "Folder on this Mac or synced drive",
                subtitle: "Save encrypted archives to a local folder, iCloud Drive or Dropbox folder. Status reports Saved to folder, not Uploaded to cloud."
            ) {
                MacButton(
                    title: "Choose folder…",
                    style: .default,
                    isEnabled: !model.isBusy && !model.needsRestart
                ) {
                    Task { await model.chooseFolder() }
                }
                .accessibilityLabel("Choose backup folder")
            }
            MacRowSeparator()
            MacRow(title: "Finish later", subtitle: "Your saved recovery code is kept. Automatic backup stays off until you connect a destination.") {
                MacButton(title: "Cancel", style: .default, isEnabled: !model.isBusy) {
                    isSetupActive = false; model.hideRecoveryCode()
                }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func submitSetupGitHubToken() {
        let token = setupTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        setupTokenInput = ""
        Task { await model.connectGitHub(token: token) }
    }

    // MARK: - Normal (Configured) State

    private var configuredSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Encrypted Backup", trailing: isFolderDestination ? "Saved to folder" : "Encrypted off-device copy")
            MacCard {
                MacRow(
                    title: model.destinationName,
                    subtitle: isFolderDestination
                        ? "Encrypted archives are saved to this folder. Syncing to another device depends on your folder provider."
                        : "Encrypted archives are uploaded to your private GitHub repository."
                ) {
                    HStack(spacing: 8) {
                        configuredStatusPill
                        MacButton(
                            title: model.isEnabled ? "Pause" : (model.recoverySaved ? "Resume" : "Set up backup"),
                            style: .default,
                            isEnabled: !model.isBusy && !model.needsRestart
                        ) {
                            if model.recoverySaved { model.setEnabled(!model.isEnabled) }
                            else { isSetupActive = true; isRestoreActive = false; model.beginSetup() }
                        }
                        .accessibilityLabel(model.isEnabled ? "Pause automatic backups" : "Resume automatic backups")

                        MacButton(
                            title: model.isBusy ? "Backing up…" : "Back up now",
                            style: .primary,
                            isEnabled: !model.isBusy && !model.needsRestart
                        ) {
                            Task { await model.backupNow() }
                        }
                        .accessibilityLabel("Back up now")
                    }
                }

                MacRowSeparator()

                MacRow(
                    title: "Last saved on this Mac",
                    subtitle: "Latest complete copy on this Mac"
                ) {
                    Text(Self.formatDate(model.lastBackupAt, emptyText: "Not saved yet"))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(MacSettingsTheme.text2)
                }

                MacRowSeparator()

                MacRow(
                    title: isFolderDestination ? "Last saved to folder" : "Last copied to GitHub",
                    subtitle: isFolderDestination
                        ? "Cloud upload is handled by your sync service"
                        : "Latest complete copy checked on GitHub"
                ) {
                    Text(Self.formatDate(model.lastRemoteBackupAt, emptyText: "Pending copy"))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(MacSettingsTheme.text2)
                }

                MacRowSeparator()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recovery code")
                                .font(.system(size: 13))
                                .foregroundStyle(MacSettingsTheme.text)
                            Text("Required to decrypt backups on another Mac. GitHub cannot recover this code.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(MacSettingsTheme.text2)
                        }
                        Spacer()
                        if !model.recoveryCode.isEmpty {
                            HStack(spacing: 8) {
                                MacButton(title: "Copy code", style: .tinted) {
                                    model.copyRecoveryCode()
                                }
                                .accessibilityLabel("Copy recovery code")

                                MacButton(title: "Hide", style: .default) {
                                    isConfiguredCodeRevealed = false
                                    model.recoveryCode = ""
                                }
                                .accessibilityLabel("Hide recovery code")
                            }
                        } else {
                            MacButton(
                                title: "Show recovery code",
                                style: .default,
                                isEnabled: !model.isBusy && !model.needsRestart
                            ) {
                                Task {
                                    await model.showRecoveryCode()
                                    isConfiguredCodeRevealed = !model.recoveryCode.isEmpty
                                }
                            }
                            .accessibilityLabel("Show recovery code")
                        }
                    }

                    if !model.recoveryCode.isEmpty {
                        Text(model.recoveryCode)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(MacSettingsTheme.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Recovery code")
                            .accessibilityValue("Revealed")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                MacRowSeparator()

                MacRow(
                    title: "Destination settings",
                    subtitle: "Clipboard external file links do not copy original files."
                ) {
                    HStack(spacing: 8) {
                        MacButton(
                            title: "Connection…",
                            style: .default,
                            isEnabled: !model.isBusy && !model.needsRestart
                        ) {
                            showRestoreConnectionOptions.toggle()
                        }
                        MacButton(
                            title: "Choose folder…",
                            style: .default,
                            isEnabled: !model.isBusy && !model.needsRestart
                        ) {
                            Task { await model.chooseFolder() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var configuredStatusPill: some View {
        if model.errorMessage != nil {
            // Never show a stale green pill when an error or offline condition is active.
            MacPill(text: "Attention needed", tone: .orange, showsDot: true)
        } else if model.isBusy {
            MacPill(text: "Backing up", tone: .blue, showsDot: true)
        } else if !model.isEnabled {
            MacPill(text: "Paused", tone: .neutral, showsDot: true)
        } else if isFolderDestination {
            MacPill(text: model.lastRemoteBackupAt == nil ? "First copy pending" : "Saved to folder", tone: model.lastRemoteBackupAt == nil ? .neutral : .green, showsDot: true)
        } else {
            MacPill(text: model.lastRemoteBackupAt == nil ? "First backup pending" : "Active", tone: model.lastRemoteBackupAt == nil ? .neutral : .green, showsDot: true)
        }
    }

    // MARK: - Restore Browser & New-Mac Restore Connection Mode

    private func restoreBrowserSection(isNewMacMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(
                title: "Restore a Backup",
                trailing: isNewMacMode ? "Works without local Keychain key" : "Encrypted versions"
            )
            MacCard {
                if isNewMacMode || showRestoreConnectionOptions {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connect backup source for restore")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(MacSettingsTheme.text)
                                Text("On a new Mac or after an SSD replacement, connect your existing GitHub backup or folder to load versions without starting a new backup setup.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(MacSettingsTheme.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if hasRestoreOnlyConnection {
                                MacPill(text: model.destinationName, tone: .blue, showsDot: true)
                            }
                            if isNewMacMode && isRestoreActive {
                                MacButton(title: "Close", style: .default) {
                                    isRestoreActive = false
                                }
                                .keyboardShortcut(.cancelAction)
                            }
                        }

                        HStack(spacing: 8) {
                            MacButton(
                                title: "Connect GitHub CLI",
                                style: .default,
                                isEnabled: !model.isBusy && !model.needsRestart
                            ) {
                                Task {
                                    await model.connectExistingGitHub()
                                    await model.refreshVersions()
                                }
                            }

                            MacButton(
                                title: "Choose folder…",
                                style: .default,
                                isEnabled: !model.isBusy && !model.needsRestart
                            ) {
                                Task {
                                    await model.chooseFolder()
                                    await model.refreshVersions()
                                }
                            }

                        }
                        HStack(spacing: 8) {
                            MacField(
                                placeholder: "GitHub access token (Contents read and write)",
                                text: $restoreTokenInput,
                                isSecure: !isRestoreTokenRevealed,
                                monospaced: true
                            )
                            .accessibilityLabel("GitHub token for restore connection")
                            .onSubmit { submitRestoreGitHubToken() }

                            MacButton(
                                title: isRestoreTokenRevealed ? "Hide" : "Show",
                                style: .ghost
                            ) {
                                isRestoreTokenRevealed.toggle()
                            }

                            MacButton(
                                title: "Connect token",
                                style: .tinted,
                                isEnabled: !model.isBusy && !model.needsRestart && !restoreTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ) {
                                submitRestoreGitHubToken()
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)

                    MacRowSeparator()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recovery code to unlock archive")
                        .font(.system(size: 13))
                        .foregroundStyle(MacSettingsTheme.text)
                    Text("Enter your saved recovery code to decrypt a version below or open an archive file from disk.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacSettingsTheme.text2)

                    HStack(spacing: 8) {
                        MacField(
                            placeholder: "Enter recovery code (XXXX-XXXX-...)",
                            text: $restoreCodeInput,
                            isSecure: !isRestoreCodeRevealed,
                            monospaced: true
                        )
                        .accessibilityLabel("Recovery code to unlock backup")

                        MacButton(
                            title: isRestoreCodeRevealed ? "Hide" : "Show",
                            style: .ghost
                        ) {
                            isRestoreCodeRevealed.toggle()
                        }
                        .accessibilityLabel(isRestoreCodeRevealed ? "Hide restore recovery code" : "Show restore recovery code")

                        MacButton(
                            title: "Choose archive…",
                            style: .default,
                            isEnabled: !model.isBusy && !model.needsRestart
                        ) {
                            let code = restoreCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await model.chooseArchive(code: code) }
                        }
                        .accessibilityLabel("Choose backup archive file from Finder")

                        MacButton(
                            title: "Refresh versions",
                            style: .default,
                            isEnabled: !model.isBusy && !model.needsRestart
                        ) {
                            Task { await model.refreshVersions() }
                        }
                        .accessibilityLabel("Refresh available backup versions")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                MacRowSeparator()

                if model.versions.isEmpty {
                    MacRow(
                        title: model.isBusy ? "Loading backup versions…" : "No backup versions loaded",
                        subtitle: "Connect your backup destination and click Refresh versions, or choose an archive file from disk."
                    ) {
                        if model.isBusy {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    ForEach(Array(model.versions.prefix(shownVersionCount))) { version in
                        if version.id != model.versions.first?.id {
                            MacRowSeparator()
                        }
                        MacRow(
                            title: Self.formatDate(version.createdAt, emptyText: version.id),
                            subtitle: Self.describeVersion(version)
                        ) {
                            MacButton(
                                title: "Preview restore…",
                                style: .tinted,
                                isEnabled: !model.isBusy && !model.needsRestart
                            ) {
                                let code = restoreCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                excludedRestoreSections.removeAll()
                                Task { await model.prepareRestore(version: version, code: code) }
                            }
                            .accessibilityLabel("Preview restore for backup from \(Self.formatDate(version.createdAt, emptyText: version.id))")
                        }
                    }
                    if model.versions.count > shownVersionCount {
                        MacRowSeparator()
                        MacRow(title: "Older versions") {
                            MacButton(title: "Show 20 more", style: .default) { shownVersionCount += 20 }
                        }
                    }
                }
            }
        }.id("backup-restore")
    }

    private func submitRestoreGitHubToken() {
        let token = restoreTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        restoreTokenInput = ""
        Task { await model.connectGitHub(token: token); await model.refreshVersions() }
    }

    // MARK: - Authenticated Restore Preview

    private func restorePreviewSection(_ preview: ArtifactBackupPreview) -> some View {
        let selectedSections = effectiveRestoreSections(for: preview)
        let availableSections = ArtifactBackupSection.allCases.filter { preview.summary.sections.contains($0) }

        return VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Restore Preview", trailing: "Authenticated backup")
            MacCard {
                MacRow(
                    title: "Backup from \(Self.formatDate(preview.summary.createdAt, emptyText: "Unknown date"))",
                    subtitle: "\(Self.formatBytes(preview.summary.totalBytes)) · \(preview.summary.fileCount) \(preview.summary.fileCount == 1 ? "file" : "files") · \(availableSections.count) \(availableSections.count == 1 ? "section" : "sections")"
                ) {
                    MacPill(text: "Verified", tone: .green, showsDot: true)
                }

                if !preview.warnings.isEmpty {
                    ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                        MacRowSeparator()
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(MacSettingsTheme.orange)
                                .padding(.top, 1)
                            Text(warning)
                                .font(.system(size: 12))
                                .foregroundStyle(MacSettingsTheme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                }

                MacRowSeparator()

                ForEach(availableSections) { section in
                    if section.id != availableSections.first?.id {
                        MacRowSeparator()
                    }
                    MacRow(
                        title: section.title,
                        subtitle: Self.sectionSubtitle(section)
                    ) {
                        MacSwitch(
                            isOn: Binding(
                                get: { selectedSections.contains(section) },
                                set: { include in
                                    if include {
                                        excludedRestoreSections.remove(section)
                                    } else {
                                        excludedRestoreSections.insert(section)
                                    }
                                }
                            ),
                            isEnabled: !model.isBusy && !model.needsRestart
                        )
                        .accessibilityLabel("Include \(section.title) in restore")
                    }
                }

                MacRowSeparator()

                VStack(alignment: .leading, spacing: 5) {
                    Label(
                        "Existing data on this Mac is saved in a local recovery copy before the restore is applied.",
                        systemImage: "arrow.uturn.backward.circle"
                    )
                    Label(
                        "Restored items apply at the next normal launch. Whytap will not force-quit or interrupt active work.",
                        systemImage: "clock.arrow.circlepath"
                    )
                    Label(
                        "Imported notification and monitor scripts stay disabled until you review them.",
                        systemImage: "checkmark.shield"
                    )
                }
                .font(.system(size: 11.5))
                .foregroundStyle(MacSettingsTheme.text2)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                MacRowSeparator()

                HStack(spacing: 10) {
                    MacButton(
                        title: "Cancel",
                        style: .default,
                        isEnabled: true
                    ) {
                        excludedRestoreSections.removeAll()
                        restoreCodeInput = ""
                        model.cancelRestore()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel restore preview")

                    Spacer()

                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    }

                    MacButton(
                        title: "Restore selected items",
                        style: .primary,
                        isEnabled: !model.isBusy && !model.needsRestart && !selectedSections.isEmpty
                    ) {
                        let sectionsToRestore = selectedSections
                        Task { await model.restore(sections: sectionsToRestore) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Restore selected items")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
    }

    private func effectiveRestoreSections(for preview: ArtifactBackupPreview) -> Set<ArtifactBackupSection> {
        preview.summary.sections.subtracting(excludedRestoreSections)
    }

    // MARK: - Local Settings History (Section Restore)

    private var localSettingsHistorySection: some View {
        let activeSnapshot = resolvedLocalSnapshot

        return VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(
                title: "Local Settings History",
                trailing: "Saved on this Mac without cloud setup"
            )
            MacCard {
                MacRow(
                    title: "Settings block",
                    subtitle: selectedConfigSection == .credentials ? "Restore provider keys from an earlier encrypted copy. Your other settings stay as they are." : "Restore one settings block. Other settings and provider keys stay as they are."
                ) {
                    MacPopup(
                        items: ConfigBackupSection.allCases.map {
                            .init(value: $0, label: $0.title)
                        },
                        selection: Binding(
                            get: { selectedConfigSection },
                            set: { newSection in
                                selectedConfigSection = newSection
                                pendingSectionRestore = nil
                            }
                        ),
                        minWidth: 185
                    )
                    .accessibilityLabel("Choose settings block to restore")
                }

                MacRowSeparator()

                if availableLocalSnapshots.isEmpty {
                    MacRow(
                        title: "No local settings snapshots yet",
                        subtitle: "Whytap saves local settings snapshots automatically on this Mac when preferences change."
                    ) {
                        EmptyView()
                    }
                } else if let snapshot = activeSnapshot {
                    MacRow(
                        title: "Saved snapshot",
                        subtitle: Self.describeSnapshot(snapshot, for: selectedConfigSection)
                    ) {
                        MacPopup(
                            items: availableLocalSnapshots.map { version in
                                .init(
                                    value: version.id,
                                    label: Self.formatDate(version.createdAt, emptyText: "Snapshot")
                                )
                            },
                            selection: Binding(
                                get: { snapshot.id },
                                set: { newID in
                                    selectedSnapshotID = newID
                                    pendingSectionRestore = nil
                                }
                            ),
                            minWidth: 160
                        )
                        .accessibilityLabel("Choose local settings snapshot version")
                    }

                    MacRowSeparator()

                    if let pending = pendingSectionRestore {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Restore “\(pending.section.title)” to \(Self.formatDate(pending.snapshot.createdAt, emptyText: "selected snapshot"))?")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(MacSettingsTheme.text)
                                Text(pending.section == .credentials ? "Provider keys in this saved copy will be restored. Other settings stay as they are." : "Only \(pending.section.title) will be restored. Other settings and provider keys stay as they are.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(MacSettingsTheme.text2)
                            }
                            Spacer(minLength: 8)
                            HStack(spacing: 8) {
                                MacButton(title: "Cancel", style: .default) {
                                    pendingSectionRestore = nil
                                }
                                .keyboardShortcut(.cancelAction)

                                MacButton(
                                    title: "Restore \(pending.section.title)",
                                    style: .primary,
                                    isEnabled: !model.isBusy && !model.needsRestart
                                ) {
                                    let section = pending.section
                                    let version = pending.snapshot
                                    pendingSectionRestore = nil
                                    Task {
                                        await model.restoreSettingsBlock(section, version: version)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    } else {
                        MacRow(
                            title: "Revert \(selectedConfigSection.title)",
                            subtitle: "Applies snapshot from \(Self.formatDate(snapshot.createdAt, emptyText: "selected date")) at the next normal launch."
                        ) {
                            MacButton(
                                title: "Restore block…",
                                style: .default,
                                isEnabled: !model.isBusy && !model.needsRestart
                            ) {
                                pendingSectionRestore = PendingSectionRestore(
                                    section: selectedConfigSection,
                                    snapshot: snapshot
                                )
                            }
                            .accessibilityLabel("Prepare restore for \(selectedConfigSection.title)")
                        }
                    }
                }
                if selectedConfigSection != .credentials {
                    MacRowSeparator()
                    MacRow(title: "App defaults", subtitle: "Reset only \(selectedConfigSection.title). Your current values are kept for recovery.") {
                        MacButton(title: "Restore defaults…", style: .default, isEnabled: !model.isBusy && !model.needsRestart) {
                            showDefaultsConfirmation = true
                        }
                    }
                }
            }
        }
    }

    private var resolvedLocalSnapshot: ConfigBackupSnapshot? {
        if let id = selectedSnapshotID,
           let match = availableLocalSnapshots.first(where: { $0.id == id }) {
            return match
        }
        return availableLocalSnapshots.first
    }

    private var availableLocalSnapshots: [ConfigBackupSnapshot] {
        selectedConfigSection == .credentials ? model.localSettingsVersions.filter { !($0.credentials?.isEmpty ?? true) } : model.localSettingsVersions
    }

    // MARK: - Formatting Helpers

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .current
        formatter.timeZone = .current
        return formatter
    }()

    static func formatDate(_ date: Date?, emptyText: String) -> String {
        guard let date else { return emptyText }
        return timestampFormatter.string(from: date)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func describeVersion(_ version: BackupVersion) -> String {
        let location: String
        switch version.location {
        case .local: location = version.pendingCopy ? "On this Mac · copy pending" : "On this Mac"
        case .folder: location = "In your selected folder"
        case .github: location = "Encrypted version on GitHub"
        case .localAndFolder: location = "On this Mac and copied to your folder"
        case .localAndGitHub: location = "On this Mac and checked on GitHub"
        }
        let purpose = version.purpose.map { $0 + " · " } ?? ""
        return purpose + formatBytes(version.size) + " · " + location
    }

    private static func sectionSubtitle(_ section: ArtifactBackupSection) -> String {
        switch section {
        case .settings:
            return "Models, hotkeys, vocabulary, Toolbox layout, display and feature preferences"
        case .credentials:
            return "Saved speech and text provider keys"
        case .caseVault:
            return "Saved Case items and secrets"
        case .meetings:
            return "Meeting notes, transcripts and staged recordings"
        case .history:
            return "Clipboard history and saved image attachments (external file links are not copied)"
        case .workspace:
            return "Custom Monitor dashboards, Notify sources and agent instructions (scripts stay paused until reviewed)"
        }
    }

    /// Summarizes only non-sensitive preference counts for the chosen section;
    /// never displays secret values.
    private static func describeSnapshot(_ snapshot: ConfigBackupSnapshot, for section: ConfigBackupSection) -> String {
        let matchingKeyCount = section == .credentials ? (snapshot.credentials?.count ?? 0) : snapshot.preferences.keys.filter { key in
            ConfigBackupRegistry.entries[key]?.section == section
        }.count
        let countLabel = matchingKeyCount == 1 ? "1 recorded setting" : "\(matchingKeyCount) recorded settings"
        return "\(snapshot.reason) · \(countLabel) in \(section.title)"
    }
}
