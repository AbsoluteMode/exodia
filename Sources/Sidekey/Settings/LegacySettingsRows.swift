import SwiftUI

// Legacy settings building blocks, still used by panels not yet migrated to the
// macOS-style `MacUI` kit (Permissions, Models, Connections). They were extracted
// out of `SettingsAccountView.swift` when Account moved to the new kit, so the
// Account file stays focused. Remove each as its consumer is migrated.

@MainActor
struct SettingsPageHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(MacSettingsTheme.text)
    }
}

@MainActor
struct SettingsRowShell<Trailing: View>: View {
    let iconName: String
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MacSettingsTheme.hover)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 1)
                    )
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(MacSettingsTheme.text)
            }
            .frame(width: 38, height: 38)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text)

            Spacer(minLength: 18)

            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MacSettingsTheme.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(MacSettingsTheme.hover, lineWidth: 1)
        )
    }
}
