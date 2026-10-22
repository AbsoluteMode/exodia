import AppKit
import SwiftUI

@MainActor
struct AgentModeView: View {
    @ObservedObject var viewModel: AgentModeViewModel
    @ObservedObject var settings: AgentSettingsStore
    @ObservedObject var store: AgentProviderStore
    @StateObject private var tavily: TavilySettings
    private let agentEnabledProvider: () -> Bool
    private let onAgentToggle: (Bool) -> Void
    private let openAPIAndModels: (AIFeature) -> Void
    @State private var agentEnabled: Bool
    @State private var message: String?
    @State private var keyHovered = false
    @FocusState private var keyFocused: Bool
    @State private var saveTask: Task<Void, Never>?

    init(viewModel: AgentModeViewModel, settings: AgentSettingsStore, store: AgentProviderStore,
         agentEnabled: @escaping () -> Bool, onAgentToggle: @escaping (Bool) -> Void,
         openAPIAndModels: @escaping (AIFeature) -> Void, tavily: TavilySettings? = nil) {
        _tavily = StateObject(wrappedValue: tavily ?? TavilySettings())
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
                Text("Whytap Agent is built in and starts directly with your selected model. Requests and relevant context go to that provider; memory and recent conversation stay on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Agent")
                    MacCard {
                        MacRow(title: "Use Agent shortcuts", subtitle: "Right Command: tap for text, hold for voice.") {
                            MacSwitch(isOn: Binding(get: { agentEnabled }, set: {
                                agentEnabled = $0; onAgentToggle($0)
                            }), label: "Use Agent shortcuts")
                        }
                        MacRowSeparator()
                        MacRow(title: "Model", subtitle: settings.selectedOpenCodeModelLabel ?? "Choose a model in API & Models") {
                            MacButton(title: "Choose model", style: .default) { openAPIAndModels(.agent) }
                        }
                        MacRowSeparator()
                        MacRow(title: "Workspace", subtitle: "~/Library/Application Support/whytap/agent\nAGENTS.md holds memory. Conversation context resets after 15 minutes.") {
                            MacButton(title: "Open folder", style: .default) {
                                do { NSWorkspace.shared.open(try AgentDaemonWorkingDirectory.ensure()) }
                                catch { message = "Couldn’t open the agent workspace." }
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    if store.activeProvider == .native {
                        MacPill(text: "Connected", tone: .green, showsDot: true)
                        Spacer()
                        MacButton(title: "Disconnect", style: .default) { viewModel.disconnect() }
                    } else {
                        if viewModel.connecting == .native { ProgressView().controlSize(.small) }
                        Spacer()
                        MacButton(title: "Connect", style: .primary) {
                            Task {
                                guard settings.selectedOpenCodeModel != nil else { message = "Choose an Agent model in API & Models."; return }
                                message = nil
                                await viewModel.connect(.native)
                            }
                        }.disabled(viewModel.connecting != nil)
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(MacSettingsTheme.text2) }
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Web search")
                    MacCard {
                        MacRow(title: "Tavily", subtitle: "Only search queries go to Tavily. Your key stays in Keychain.") {
                            MacPill(text: tavily.configured ? "Connected" : "Not connected", tone: tavily.configured ? .green : .neutral, showsDot: true)
                        }
                        MacRowSeparator()
                        VStack(alignment: .leading, spacing: 10) {
                            SecureField(tavily.configured ? "Replace Tavily API key" : "Tavily API key", text: $tavily.draftKey)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                                    keyFocused ? MacSettingsTheme.accent : keyHovered && !tavily.saving ? MacSettingsTheme.text2 : MacSettingsTheme.switchBorder,
                                    lineWidth: keyFocused ? 2 : keyHovered && !tavily.saving ? 1 : 0.5))
                                .onHover { keyHovered = $0 }
                                .focused($keyFocused)
                                .opacity(tavily.saving ? 0.42 : 1)
                                .accessibilityLabel("Tavily API key")
                                .disabled(tavily.saving)
                                .onSubmit { saveSearchKey() }
                            HStack(spacing: 10) {
                                MacButton(title: "Get API key", style: .ghost) {
                                    NSWorkspace.shared.open(URL(string: "https://app.tavily.com/home")!)
                                }
                                if tavily.saving { ProgressView().controlSize(.small) }
                                Spacer()
                                if tavily.configured {
                                    MacButton(title: "Remove key", style: .default) { tavily.remove() }
                                        .disabled(tavily.saving)
                                }
                                MacButton(title: "Save key", style: .primary) { saveSearchKey() }
                                    .disabled(tavily.saving || tavily.draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            if let message = tavily.message {
                                Text(message).font(.caption).foregroundStyle(MacSettingsTheme.text2)
                                    .accessibilityAddTraits(.updatesFrequently)
                            }
                        }.padding(14)
                    }
                }
                MacCard {
                    MacRow(title: "Allow file edits and commands",
                           subtitle: "Uses your Mac user’s permissions. Off: edits and shell commands are blocked. Applies to the next request.") {
                        MacSwitch(isOn: $settings.openCodeAllowActions, label: "Allow file edits and commands")
                    }
                }

            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { agentEnabled = agentEnabledProvider() }
        .onDisappear { saveTask?.cancel(); tavily.draftKey = "" }
        .onReceive(NotificationCenter.default.publisher(for: .sidekeyCapabilityFlagsChanged)) { _ in
            agentEnabled = agentEnabledProvider()
        }
    }

    private func saveSearchKey() {
        guard !tavily.saving else { return }
        saveTask = Task { await tavily.save() }
    }
}
