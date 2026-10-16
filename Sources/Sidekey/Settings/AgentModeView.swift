import SwiftUI

@MainActor
struct AgentModeView: View {
    @ObservedObject var viewModel: AgentModeViewModel
    @ObservedObject var settings: AgentSettingsStore
    @ObservedObject var store: AgentProviderStore
    private let agentEnabledProvider: () -> Bool
    private let onAgentToggle: (Bool) -> Void
    @State private var agentEnabled: Bool
    @State private var apiKey = ""
    @State private var hasSavedKey = false
    @State private var installed = false
    @State private var installing = false
    @State private var message: String?
    @State private var modelSearch = ""

    init(viewModel: AgentModeViewModel, settings: AgentSettingsStore, store: AgentProviderStore,
         agentEnabled: @escaping () -> Bool, onAgentToggle: @escaping (Bool) -> Void) {
        self.viewModel = viewModel
        self.settings = settings
        self.store = store
        self.agentEnabledProvider = agentEnabled
        self.onAgentToggle = onAgentToggle
        _agentEnabled = State(initialValue: agentEnabled())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("OpenCode runs your agent on this Mac. Choose any OpenRouter model and use your own API key. Project memory and conversation sessions stay separate on your Mac; your requests and selected context are sent to the model provider.")
                    .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if store.legacyConnectionNeedsSetup {
                    Text("Agent now uses OpenCode. Choose your OpenRouter model and press Save & connect to reconnect. Your previous CLI credentials remain on this Mac.")
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
            hasSavedKey = (try? OpenRouterLLMKeyStore().read())?.isEmpty == false
            installed = await Task.detached { OpenCodeBinaryLocator().locate() != nil }.value
            if hasSavedKey { await settings.refreshOpenRouterCatalog() }
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
                       subtitle: "Whytap can install a verified copy for this app. Existing terminal installations stay available.") {
                    MacButton(title: installing ? "Installing…" : installed ? "Update app copy" : "Install", style: .default) {
                        Task { await install() }
                    }.disabled(installing)
                }
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacGroupTitle(title: "OpenRouter")
            SecureField(hasSavedKey ? "Key saved — enter to replace" : "API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            Text("The key is shared with Models and saved in your Mac Keychain.")
                .font(.caption).foregroundStyle(MacSettingsTheme.text2)
            TextField("Model ID, for example provider/model", text: Binding(
                get: { settings.openCodeModel ?? "" }, set: { settings.openCodeModel = $0 }))
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Find a model", text: $modelSearch).textFieldStyle(.roundedBorder)
                Menu("Choose model") {
                    ForEach(matchingModels) { model in
                        Button(model.displayName) { settings.openCodeModel = model.id }
                    }
                    if matchingModels.isEmpty { Text("Refresh the catalog to choose a model") }
                }
                Button("Refresh") { Task { await refreshModels() } }
                    .disabled(settings.openRouterCatalogLoading)
                if settings.openRouterCatalogLoading { ProgressView().controlSize(.small) }
            }
            if let error = settings.openRouterCatalogError {
                Text(error).font(.caption).foregroundStyle(MacSettingsTheme.text2)
            }
            Text("Enter an exact OpenRouter model ID or choose from the live catalog. OpenRouter charges your own account for requests.")
                .font(.caption).foregroundStyle(MacSettingsTheme.text2)
        }
    }

    private var matchingModels: [OpenRouterModelOption] {
        let query = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(settings.openRouterCatalog.filter {
            query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
        }.prefix(200))
    }

    private func saveKeyIfEntered() throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try OpenRouterLLMKeyStore().save(key: key)
        hasSavedKey = true
        apiKey = ""
    }

    private func refreshModels() async {
        do { try saveKeyIfEntered() }
        catch { message = "Couldn’t save the OpenRouter key to Keychain."; return }
        await settings.refreshOpenRouterCatalog()
    }

    private func connect() async {
        guard settings.selectedOpenCodeModel != nil else { message = "Choose an OpenRouter model first."; return }
        do { try saveKeyIfEntered() }
        catch { message = "Couldn’t save the OpenRouter key to Keychain."; return }
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
