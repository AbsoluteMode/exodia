import SwiftUI

@MainActor
struct AgentModeView: View {
    @ObservedObject var viewModel: AgentModeViewModel
    @ObservedObject var settings: AgentSettingsStore
    @ObservedObject var store: AgentProviderStore
    private let agentEnabledProvider: () -> Bool
    private let onAgentToggle: (Bool) -> Void
    private let openAPIAndModels: (AIFeature) -> Void
    @State private var agentEnabled: Bool
    @State private var installed = false
    @State private var installing = false
    @State private var message: String?

    init(viewModel: AgentModeViewModel, settings: AgentSettingsStore, store: AgentProviderStore,
         agentEnabled: @escaping () -> Bool, onAgentToggle: @escaping (Bool) -> Void,
         openAPIAndModels: @escaping (AIFeature) -> Void) {
        self.viewModel = viewModel
        self.settings = settings
        self.store = store
        self.agentEnabledProvider = agentEnabled
        self.onAgentToggle = onAgentToggle
        self.openAPIAndModels = openAPIAndModels
        _agentEnabled = State(initialValue: agentEnabled())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("OpenCode runs your agent on this Mac. Choose the model and add your OpenRouter key in API & Models. Project memory and conversation sessions stay separate on your Mac; your requests and selected context are sent to the model provider.")
                    .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if store.legacyConnectionNeedsSetup {
                    Text("Agent now uses OpenCode. Choose a model in API & Models, then press Save & connect to reconnect. Your previous CLI credentials remain on this Mac.")
                        .font(.caption).foregroundStyle(MacSettingsTheme.text2)
                }
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Agent")
                    MacCard {
                        MacRow(title: "Use Agent shortcuts", subtitle: "Right Command: tap for text, hold for voice.") {
                            MacSwitch(isOn: Binding(get: { agentEnabled }, set: {
                                agentEnabled = $0; onAgentToggle($0)
                            }))
                        }
                    }
                }
                installationSection
                modelSection
                MacCard {
                    MacRow(title: "Allow agent actions",
                           subtitle: "The agent can edit files and run commands, including tests, with your Mac user’s permissions.") {
                        MacSwitch(isOn: $settings.openCodeAllowActions)
                    }
                }
                HStack(spacing: 12) {
                    if viewModel.connecting == .opencode || installing { ProgressView().controlSize(.small) }
                    if store.activeProvider == .opencode {
                        MacPill(text: "Connected", tone: .green, showsDot: true)
                        MacButton(title: "Disconnect", style: .default) { viewModel.disconnect() }
                    }
                    Spacer()
                    MacButton(title: "Save & connect", style: .primary) { Task { await connect() } }
                        .disabled(installing || viewModel.connecting != nil)
                }
                if let message { Text(message).font(.caption).foregroundStyle(MacSettingsTheme.text2) }
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            installed = await Task.detached { OpenCodeBinaryLocator().locate() != nil }.value
        }
        .onAppear { agentEnabled = agentEnabledProvider() }
        .onReceive(NotificationCenter.default.publisher(for: .sidekeyCapabilityFlagsChanged)) { _ in
            agentEnabled = agentEnabledProvider()
        }
    }

    private var installationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "OpenCode")
            MacCard {
                MacRow(title: installed ? "OpenCode is installed" : "Install OpenCode",
                       subtitle: "Exodia can install a verified copy for this app. Existing terminal installations stay available.") {
                    MacButton(title: installing ? "Installing…" : installed ? "Update app copy" : "Install", style: .default) {
                        Task { await install() }
                    }.disabled(installing)
                }
            }
        }
    }

    private var modelSection: some View {
        MacCard {
            MacRow(title: "Model", subtitle: settings.selectedOpenCodeModelLabel ?? "Choose a model in API & Models") {
                MacButton(title: "Change in API & Models", style: .default) { openAPIAndModels(.agent) }
            }
        }
    }

    private func connect() async {
        guard settings.selectedOpenCodeModel != nil else { message = "Choose a model in API & Models."; return }
        message = nil
        await viewModel.connect(.opencode)
    }

    private func install() async {
        installing = true
        message = nil
        defer { installing = false }
        do {
            let version = try await OpenCodeInstaller().install()
            installed = true
            message = "OpenCode \(version) installed. Choose a model and press Save & connect."
        } catch {
            message = (error as? OpenCodeInstallError)?.localizedDescription ?? "Couldn’t install OpenCode. Check your connection and retry."
        }
    }
}
