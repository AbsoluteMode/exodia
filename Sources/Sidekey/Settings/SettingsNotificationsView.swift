import SwiftUI

@MainActor
struct SettingsNotificationsView: View {
    @ObservedObject private var supervisor: NotifyScriptSupervisor

    init(supervisor: NotifyScriptSupervisor? = nil) {
        self.supervisor = supervisor ?? .shared
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notifications")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                    Text("Sources connected by your agent appear here. Turn off a source to stop its notifications.")
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text2)
                }

                if let error = supervisor.error {
                    MacBanner(tone: .warn, systemImage: "exclamationmark.triangle", text: error)
                }

                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Connected sources")
                    MacCard {
                        if supervisor.sources.isEmpty {
                            VStack(spacing: 9) {
                                Image(systemName: "bell")
                                    .font(.system(size: 26))
                                    .foregroundStyle(MacSettingsTheme.text2)
                                Text("No sources connected")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(MacSettingsTheme.text)
                                Text("Ask your agent to connect the notifications you want.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(MacSettingsTheme.text2)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(28)
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(supervisor.sources) { source in
                                if source.id != supervisor.sources.first?.id { MacRowSeparator() }
                                MacRow(title: source.script.name, subtitle: source.message) {
                                    NotificationSourceIcon(
                                        glyph: NotifyLogoStore.resolve(logo: source.script.logo, source: source.script.name),
                                        tint: Color(hexCSS: source.script.tint ?? "#299FD6"), size: 28
                                    )
                                    .accessibilityHidden(true)
                                } trailing: {
                                    MacSwitch(isOn: Binding(
                                        get: { supervisor.sources.first(where: { $0.id == source.id })?.script.enabled ?? false },
                                        set: { supervisor.setEnabled($0, id: source.id) }
                                    ))
                                    .accessibilityLabel("Enable \(source.script.name)")
                                }
                            }
                        }
                    }
                }

                Text("Sources run while Whytap is open. Turning one off keeps its setup and notification history, so you can enable it again anytime.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
