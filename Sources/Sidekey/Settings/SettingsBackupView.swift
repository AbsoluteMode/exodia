import AppKit
import SwiftUI

@MainActor
struct SettingsBackupView: View {
    @ObservedObject var model: BackupViewModel
    var openIntegrations: () -> Void
    @State private var showRestore: Bool
    @State private var restoreCode = ""
    @FocusState private var isRestoreCodeFocused: Bool

    init(model: BackupViewModel = .shared, showRestore: Bool = false,
         openIntegrations: @escaping () -> Void = {}) {
        self.model = model
        self.openIntegrations = openIntegrations
        _showRestore = State(initialValue: showRestore)
    }

    private var actionsEnabled: Bool {
        model.canUseGitHubBackup && !model.isBusy && !model.needsRestart && !model.hasPendingMaintenance
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Backup").font(.system(size: 20, weight: .semibold))
                    Spacer()
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        if model.canCancelOperation {
                            MacButton(title: "Cancel", style: .default) { model.cancelCurrentOperation() }
                        }
                    }
                }
                MacCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Label(model.syncState.title, systemImage: model.syncState.systemImage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(model.syncState == .synced ? MacSettingsTheme.green : MacSettingsTheme.text)
                            Spacer()
                            if let url = model.githubBackupURL {
                                IntegrationLink(title: "GitHub ↗", destination: url)
                                    .font(.system(size: 12))
                                    .foregroundStyle(MacSettingsTheme.text)
                                    .accessibilityLabel("Open backup on GitHub")
                            }
                            if !model.canUseGitHubBackup {
                                MacButton(title: "Connect GitHub", style: .tinted, isEnabled: !model.isBusy) {
                                    openIntegrations()
                                }
                            }
                        }
                        HStack(spacing: 10) {
                            MacButton(title: "Back up", style: .primary, isEnabled: actionsEnabled) {
                                showRestore = false; restoreCode = ""
                                Task { await model.backupEverything() }
                            }
                            MacButton(title: "Restore backup", style: .default, isEnabled: actionsEnabled) {
                                model.hideRecoveryCode(); model.clearError(); showRestore = true
                            }
                        }
                    }
                    .padding(14)
                }
                if showRestore && !model.needsRestart {
                    MacCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SecureField("Recovery code", text: $restoreCode)
                                .textFieldStyle(.roundedBorder)
                                .focused($isRestoreCodeFocused)
                                .onSubmit { restore() }
                                .accessibilityLabel("Recovery code")
                            MacButton(title: "Restore", style: .primary,
                                      isEnabled: actionsEnabled && !restoreCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                                restore()
                            }
                        }.padding(14)
                    }
                }
                if !model.recoveryCode.isEmpty {
                    MacCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recovery code").font(.system(size: 13, weight: .semibold))
                            Text(model.recoveryCode).font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text("Keep this code to restore your backup.")
                                    .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                                Spacer()
                                MacButton(title: "Copy code", style: .default) { model.copyRecoveryCode() }
                            }
                        }.padding(14)
                    }
                }
                if model.isBusy {
                    Text(model.statusText).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                }
                if let error = model.errorMessage {
                    MacBanner(tone: .warn, systemImage: "exclamationmark.triangle", title: "Couldn't finish", text: error)
                }
                if model.needsRestart {
                    MacBanner(tone: .info, systemImage: "arrow.clockwise", title: "Restore is ready",
                              text: "Quit Whytap and open it again to finish.")
                    MacButton(title: "Cancel restore", style: .default, isEnabled: !model.isBusy) {
                        model.cancelPlannedRestore()
                    }
                }
                if model.hasPendingMaintenance {
                    HStack {
                        MacButton(title: "Finish backup management", style: .default, isEnabled: !model.isBusy) {
                            Task { await model.resumeBackupManagement() }
                        }
                        MacButton(title: "Stop and keep copies", style: .ghost, isEnabled: !model.isBusy) {
                            Task { await model.stopBackupManagement() }
                        }
                    }
                }
                if let warning = model.managementWarning {
                    MacBanner(tone: .warn, systemImage: "exclamationmark.triangle", title: "Previous backups", text: warning)
                    MacButton(title: "Show kept copies", style: .default) { model.showRetainedBackups() }
                }
                if let notice = model.restoreNotice {
                    MacBanner(tone: notice.state == .applied ? .info : .warn,
                              systemImage: "arrow.counterclockwise", title: notice.message,
                              text: notice.warnings.joined(separator: " "))
                    MacButton(title: "Dismiss", style: .ghost) { model.dismissRestoreNotice() }
                }
                if model.recoveryCheckpoint != nil {
                    MacButton(title: "Show previous data", style: .default) { model.showRecoveryFiles() }
                }
                ForEach(model.parkedItems) { item in
                    MacCard {
                        MacRow(title: item.title, subtitle: "Restored · paused") {
                            MacButton(title: "Show files", style: .default) { model.showParkedFiles(item) }
                            MacButton(title: "Enable", style: .tinted, isEnabled: !model.isBusy && !model.needsRestart) {
                                model.activateRecoveredItem(item)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(MacSettingsTheme.text)
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .focusable(false)
        .task { await model.checkGitHubConnection() }
        .onChange(of: showRestore) { _, shown in isRestoreCodeFocused = shown }
        .onDisappear { clearCode() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window.title.contains("Settings") { clearCode() }
        }
    }

    private func restore() {
        guard actionsEnabled, !restoreCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let code = restoreCode; restoreCode = ""
        Task { await model.restoreEverything(code: code) }
    }

    private func clearCode() { restoreCode = ""; model.hideRecoveryCode() }
}
