import AppKit
import SwiftUI

/// Registrations are persistent connections, not live process activity.
struct IslandCaseConnectedApps: View {
    let registrations: [CaseAppRegistration]
    let onOpenAccess: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                if registrations.isEmpty {
                    Button(action: onOpenAccess) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .help("Подключить приложение")
                    .accessibilityLabel("Подключить приложение к Case")
                    .accessibilityIdentifier("case.access.open")
                } else {
                    ForEach(registrations) { app in
                        Button(action: onOpenAccess) {
                            appIcon(app)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .help(app.displayName)
                        .accessibilityLabel("\(app.displayName), подключено к Case. Настроить доступ")
                        .accessibilityIdentifier("case.access.app.\(app.id)")
                    }
                }
            }
        }
        .frame(height: 28)
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.88))
    }

    static func brandAsset(for identity: CaseAppIdentity) -> String? {
        switch CaseKnownClient(identity: identity) {
        case .claudeCode: return "claude-code"
        case .codex: return "codex"
        default: return nil
        }
    }

    @ViewBuilder
    private func appIcon(_ app: CaseAppRegistration) -> some View {
        if let asset = Self.brandAsset(for: app.identity) {
            ProviderBrandIcon(assetName: asset, size: 18, color: .white.opacity(0.88))
        } else if case let .executablePath(path) = app.identity,
                  FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        } else {
            Image(systemName: app.identity == .builtInOpenCode ? "terminal" : "app")
                .font(.system(size: 17, weight: .medium))
                .accessibilityHidden(true)
        }
    }
}
