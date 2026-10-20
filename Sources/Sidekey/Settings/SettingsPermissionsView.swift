import SwiftUI

@MainActor
struct SettingsPermissionsView: View {
    @ObservedObject var viewModel: PermissionsSettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Permissions")
                    MacCard {
                        permissionRow(
                            icon: "keyboard.fill",
                            title: "Keyboard control",
                            granted: viewModel.snapshot.accessibilityGranted,
                            status: viewModel.snapshot.accessibilityGranted ? "Allowed" : "Required",
                            actionTitle: "Open",
                            action: viewModel.requestAccessibility
                        )
                        MacRowSeparator()
                        permissionRow(
                            icon: "mic.fill",
                            title: "Microphone",
                            granted: viewModel.snapshot.microphoneGranted,
                            status: viewModel.microphoneLabel,
                            actionTitle: "Allow",
                            action: viewModel.requestMicrophone
                        )
                        MacRowSeparator()
                        permissionRow(
                            icon: "rectangle.dashed.badge.record",
                            title: "Screen Recording",
                            subtitle: "For screenshots. If macOS asks to reopen Whytap, finish your current work first.",
                            granted: viewModel.screenRecordingGranted,
                            status: viewModel.screenRecordingGranted ? "Allowed" : "Not allowed",
                            actionTitle: viewModel.screenRecordingGranted ? "Open" : "Allow",
                            action: viewModel.requestScreenRecording
                        )
                    }
                }

                DropShortcutStatusSection(viewModel: viewModel)
                MacButton(title: "Refresh", style: .default) { viewModel.refresh() }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { viewModel.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refresh(restartRecoveryPolling: false)
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String? = nil,
        granted: Bool,
        status: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        MacRow(
            title: title,
            subtitle: subtitle,
            leading: {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .frame(width: 22)
            },
            trailing: {
                HStack(spacing: 10) {
                    MacPill(text: status, tone: granted ? .green : .orange, showsDot: true)
                    MacButton(title: actionTitle, style: .default, action: action)
                }
            }
        )
    }
}
