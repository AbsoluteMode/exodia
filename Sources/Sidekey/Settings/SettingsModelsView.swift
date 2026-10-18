import SwiftUI

@MainActor
struct SettingsModelsView: View {
    @ObservedObject var viewModel: SettingsModelsViewModel
    private var displayedProviders: [BYOKProvider] { BYOKProvider.selectable }

    /// Canonical user-facing name for the user-supplied OpenAI-compatible
    /// self-hosted endpoint. Shared by the STT "Your key" provider list and
    /// the LLM "Your key" variant list so both panels read identically.
    static let selfHostedProviderName = "Self-hosted (OpenAI-compatible)"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                transcribeSection
                llmSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Transcription

    private var transcribeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Transcription")
            if viewModel.approvedLevel == nil {
                MacBanner(
                    tone: .warn,
                    systemImage: "exclamationmark.triangle",
                    text: "No transcription provider is set up, so Drop is off. Pick one below, enter your key and press Save."
                )
                .padding(.bottom, 12)
            }
            yourKeyConfig
        }
    }

    // MARK: - Your-key level (BYOK, direct to provider)

    @ViewBuilder
    private var yourKeyConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacBanner(
                tone: .privacy,
                systemImage: "lock.shield",
                text: "Transcription goes straight to the provider with your key. Nothing passes through any Exodia server."
            )


            VStack(alignment: .leading, spacing: 0) {
                MacGroupTitle(
                    title: "Provider",
                    trailing: "\(providerName(viewModel.provider)) · \(activeModelLabel)"
                )
                VStack(spacing: 8) {
                    ForEach(displayedProviders, id: \.self) { provider in
                        if provider == viewModel.provider {
                            expandedProviderCard(provider)
                        } else {
                            collapsedProviderRow(provider)
                        }
                    }
                }
            }
        }
    }

    private var activeModelLabel: String {
        viewModel.provider == .selfHosted
            ? (viewModel.selfHostedModel.isEmpty ? "model" : viewModel.selfHostedModel)
            : viewModel.selectedModel
    }

    private func collapsedProviderRow(_ provider: BYOKProvider) -> some View {
        MacCard {
            Button {
                guard viewModel.provider != provider else { return }
                viewModel.provider = provider
                viewModel.providerChanged()
            } label: {
                MacRow(
                    title: providerName(provider),
                    leading: { byokProviderBrandIcon(provider) }
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func expandedProviderCard(_ provider: BYOKProvider) -> some View {
        MacCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    byokProviderBrandIcon(provider)
                    Text(providerName(provider))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                    if viewModel.approvedLevel != nil {
                        MacPill(text: "Active", tone: .blue)
                    }
                    Spacer()
                }

                fieldLabel("Model")
                modelField(provider)

                if provider == .selfHosted {
                    fieldLabel("Base URL")
                    MacField(placeholder: "https://…", text: $viewModel.selfHostedBaseURL)
                }

                fieldLabel("API key")
                MacField(
                    placeholder: provider == .openAI ? "sk-…" : "API key",
                    text: $viewModel.apiKeyInput,
                    isSecure: true,
                    monospaced: true
                )

                HStack(spacing: 10) {
                    MacButton(
                        title: "Save",
                        style: .primary,
                        isEnabled: viewModel.connectionStatus != .testing
                    ) {
                        Task { await viewModel.saveCurrentSelection() }
                    }
                    if provider == .openAI || provider == .selfHosted {
                        MacButton(title: "Test connection", style: .default) {
                            Task { await viewModel.testConnection() }
                        }
                    }

                    connectionStatus
                }
                .padding(.top, 2)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func modelField(_ provider: BYOKProvider) -> some View {
        if provider == .selfHosted {
            MacField(placeholder: "gpt-4o-transcribe", text: $viewModel.selfHostedModel)
        } else if viewModel.models.count > 1 {
            MacPopup(
                items: viewModel.models.map { .init(value: $0, label: $0) },
                selection: Binding(
                    get: { viewModel.selectedModel },
                    set: { viewModel.selectedModel = $0 }
                )
            )
        } else {
            // Single fixed model for this provider — show it as text, not an
            // illusory one-option dropdown (Deepgram / Soniox / ElevenLabs each
            // offer exactly one realtime model).
            Text(viewModel.models.first ?? viewModel.selectedModel)
                .font(.system(size: 13))
                .foregroundStyle(MacSettingsTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch viewModel.connectionStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small).padding(.leading, 4)
        case .ok:
            MacPill(text: "Connected", tone: .green, showsDot: true)
        case .failed(let msg):
            MacPill(text: msg, tone: .red)
        }
    }

    // MARK: - LLM section

    private var llmSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(
                title: "Smart processing LLM",
                trailing: llmTrailingTitle
            )
            if viewModel.approvedLLMLevel == nil {
                MacBanner(
                    tone: .info,
                    systemImage: "info.circle",
                    text: "No LLM is set up. Drop pastes the plain transcript and meeting notes wait until you save a route below."
                )
                .padding(.bottom, 12)
            }
            yourKeyLLMConfig
        }
    }

    /// "Your key" sub-panel: a provider-card list (OpenRouter / Self-hosted)
    /// matching the STT "Your key" panel — collapsed rows with a chevron expand
    /// into the active route's config card. The active card reuses the existing
    /// `openRouterConfig` / `customLLMConfig` panels unchanged.
    @ViewBuilder
    private var yourKeyLLMConfig: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(
                title: "Provider",
                trailing: llmVariantName(viewModel.llmLevel)
            )
            VStack(spacing: 8) {
                ForEach(llmYourKeyVariants, id: \.self) { variant in
                    if variant == viewModel.llmLevel {
                        expandedLLMVariantCard(variant)
                    } else {
                        collapsedLLMVariantRow(variant)
                    }
                }
            }
        }
    }

    /// The two BYOK LLM sub-routes, in display order (OpenRouter first).
    private var llmYourKeyVariants: [LLMIsolationLevel] { [.yourKey, .custom] }

    private func llmVariantName(_ variant: LLMIsolationLevel) -> String {
        variant == .custom ? Self.selfHostedProviderName : "OpenRouter"
    }

    @ViewBuilder
    private func llmVariantBrandIcon(_ variant: LLMIsolationLevel) -> some View {
        if variant == .custom {
            ProviderBrandIcon(systemName: "server.rack")
        } else {
            ProviderBrandIcon(assetName: "openrouter")
        }
    }

    private func collapsedLLMVariantRow(_ variant: LLMIsolationLevel) -> some View {
        MacCard {
            Button {
                guard viewModel.llmLevel != variant else { return }
                viewModel.selectLLMLevel(variant)
            } label: {
                MacRow(
                    title: llmVariantName(variant),
                    leading: { llmVariantBrandIcon(variant) }
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func expandedLLMVariantCard(_ variant: LLMIsolationLevel) -> some View {
        if variant == .custom {
            customLLMConfig
        } else {
            openRouterConfig
        }
    }

    private var openRouterConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacBanner(
                tone: .privacy,
                systemImage: "lock.shield",
                text: "Drop cleanup and meeting notes go straight to OpenRouter with your key. Agent Mode still uses the provider selected on the Agent tab."
            )


            MacCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ProviderBrandIcon(assetName: "openrouter")
                        Text("OpenRouter direct")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MacSettingsTheme.text)
                        if viewModel.approvedLLMLevel != nil {
                            MacPill(text: "Route active", tone: .blue)
                        }
                        Spacer()
                    }

                    openRouterRouteStatus

                    fieldLabel("OpenRouter model ID")
                    LLMModelSearchField(
                        placeholder: "openai/gpt-4o-mini",
                        text: $viewModel.openRouterModel,
                        suggestions: viewModel.openRouterModelSuggestions
                    )
                    .task { await viewModel.loadOpenRouterModelsIfNeeded() }

                    caption("The provider prefix is part of the OpenRouter model id, for example openai/…, anthropic/…, or google/….")


                    if usingOpenRouterAuto {
                        MacBanner(
                            tone: .info,
                            systemImage: "arrow.triangle.branch",
                            text: "Auto Router lets OpenRouter choose the concrete model. Pick a specific model id when you want predictable provider names."
                        )
                    }

                    fieldLabel("OpenRouter API key")
                    MacField(
                        placeholder: "sk-or-v1-…",
                        text: $viewModel.openRouterAPIKeyInput,
                        isSecure: true,
                        monospaced: true
                    )

                    HStack(spacing: 10) {
                        MacButton(
                            title: "Save",
                            style: .primary,
                            isEnabled: viewModel.llmConnectionStatus != .testing
                        ) {
                            Task { await viewModel.saveCurrentLLMSelection() }
                        }
                        MacButton(title: "Test OpenRouter", style: .default) {
                            Task { await viewModel.testLLMConnection() }
                        }
                        MacButton(title: "Refresh list", style: .default) {
                            Task { await viewModel.refreshOpenRouterModels() }
                        }

                        llmConnectionStatus
                    }
                    .padding(.top, 2)
                }
                .padding(14)
            }
        }
    }

    private var customLLMConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacBanner(
                tone: .privacy,
                systemImage: "lock.shield",
                text: "Drop cleanup and meeting notes go straight to your OpenAI-compatible endpoint. Agent Mode still uses the provider selected on the Agent tab."
            )


            MacCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ProviderBrandIcon(systemName: "server.rack")
                        Text(Self.selfHostedProviderName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MacSettingsTheme.text)
                        if viewModel.approvedLLMLevel != nil {
                            MacPill(text: "Route active", tone: .blue)
                        }
                        Spacer()
                    }

                    customLLMRouteStatus

                    fieldLabel("Base URL")
                    MacField(
                        placeholder: "http://localhost:8000/v1",
                        text: $viewModel.customLLMBaseURL,
                        monospaced: true
                    )

                    caption("Use the OpenAI-compatible API root, usually ending with /v1 for vLLM, LiteLLM, Ollama, or an internal gateway.")

                    fieldLabel("Model ID")
                    LLMModelSearchField(
                        placeholder: "local-model",
                        text: $viewModel.customLLMModel,
                        suggestions: viewModel.customLLMModelSuggestions
                    )
                    .task { await viewModel.loadCustomLLMModelsIfNeeded() }

                    fieldLabel("API key")
                    MacField(
                        placeholder: "Bearer token, optional",
                        text: $viewModel.customLLMAPIKeyInput,
                        isSecure: true,
                        monospaced: true
                    )

                    HStack(spacing: 10) {
                        MacButton(
                            title: "Save",
                            style: .primary,
                            isEnabled: viewModel.llmConnectionStatus != .testing
                        ) {
                            Task { await viewModel.saveCurrentLLMSelection() }
                        }
                        MacButton(title: "Test endpoint", style: .default) {
                            Task { await viewModel.testLLMConnection() }
                        }
                        MacButton(title: "Refresh list", style: .default) {
                            Task { await viewModel.refreshCustomLLMModels() }
                        }

                        llmConnectionStatus
                    }
                    .padding(.top, 2)
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private var llmConnectionStatus: some View {
        switch viewModel.llmConnectionStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small).padding(.leading, 4)
        case .ok:
            MacPill(text: "LLM route OK", tone: .green, showsDot: true)
        case .failed(let msg):
            MacPill(text: msg, tone: .red)
        }
    }

    // MARK: - Helpers

    private var llmTrailingTitle: String {
        guard viewModel.approvedLLMLevel != nil else { return "Route: Not set up" }
        switch viewModel.llmLevel {
        case .yourKey:
            return "Route: OpenRouter direct"
        case .custom:
            return "Route: Self-hosted"
        }
    }

    private var currentOpenRouterModelID: String {
        let trimmed = viewModel.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SelfKeyPreferences.defaultOpenRouterModel : trimmed
    }

    private var currentCustomLLMBaseURL: String {
        let trimmed = viewModel.customLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Not set" : trimmed
    }

    private var currentCustomLLMModelID: String {
        let trimmed = viewModel.customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SelfKeyPreferences.defaultCustomLLMModel : trimmed
    }

    private var usingOpenRouterAuto: Bool {
        currentOpenRouterModelID == "openrouter/auto"
    }

    private var openRouterRouteStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            llmFactRow(title: "Used for", value: "Drop cleanup + meeting notes")
            llmFactRow(title: "Route", value: "OpenRouter /chat/completions")
            llmFactRow(title: "Selected model", value: currentOpenRouterModelID, monospaced: true)
        }
        .padding(10)
        .background(MacSettingsTheme.controlBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var customLLMRouteStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            llmFactRow(title: "Used for", value: "Drop cleanup + meeting notes")
            llmFactRow(title: "Route", value: "OpenAI-compatible /chat/completions")
            llmFactRow(title: "Base URL", value: currentCustomLLMBaseURL, monospaced: true)
            llmFactRow(title: "Selected model", value: currentCustomLLMModelID, monospaced: true)
        }
        .padding(10)
        .background(MacSettingsTheme.controlBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private func llmFactRow(title: String, value: String, monospaced: Bool = false) -> some View {
        let valueFont = monospaced
            ? Font.system(size: 12, weight: .medium, design: .monospaced)
            : Font.system(size: 12, weight: .medium)

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MacSettingsTheme.text2)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(valueFont)
                .foregroundStyle(MacSettingsTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func providerName(_ provider: BYOKProvider) -> String {
        switch provider {
        case .openAI: return "OpenAI"
        case .selfHosted: return Self.selfHostedProviderName
        case .deepgram: return "Deepgram"
        case .soniox: return "Soniox"
        case .elevenLabs: return "ElevenLabs"
        }
    }

    @ViewBuilder
    private func byokProviderBrandIcon(_ provider: BYOKProvider) -> some View {
        if let assetName = byokProviderBrandAssetName(provider) {
            ProviderBrandIcon(assetName: assetName)
        } else {
            ProviderBrandIcon(systemName: "server.rack")
        }
    }

    private func byokProviderBrandAssetName(_ provider: BYOKProvider) -> String? {
        switch provider {
        case .openAI: return "openai"
        case .selfHosted: return nil
        case .deepgram: return "deepgram"
        case .soniox: return "soniox"
        case .elevenLabs: return "elevenlabs"
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(MacSettingsTheme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MacSettingsTheme.text2)
            .textCase(.uppercase)
            .kerning(0.4)
    }

}

private struct LLMModelSearchField: View {
    let placeholder: String
    @Binding var text: String
    let suggestions: [OpenRouterModelOption]

    private static let suggestionsMaxHeight: CGFloat = 220

    @FocusState private var focused: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(MacSettingsTheme.text)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            focused ? MacSettingsTheme.accent.opacity(0.6) : Color.white.opacity(0.12),
                            lineWidth: focused ? 2 : 0.5
                        )
                )
                .onTapGesture { expanded = true }
                .onSubmit { expanded = false }
                .onChange(of: focused) { _, isFocused in
                    expanded = isFocused
                }
                .onChange(of: text) { _, _ in
                    if focused { expanded = true }
                }

            if expanded && !suggestions.isEmpty {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, option in
                            if idx > 0 { MacRowSeparator() }
                            Button {
                                text = option.id
                                expanded = false
                                focused = false
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.id)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundStyle(MacSettingsTheme.text)
                                            .lineLimit(1)
                                        if option.name != option.id {
                                            Text(option.name)
                                                .font(.system(size: 11))
                                                .foregroundStyle(MacSettingsTheme.text2)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if option.id == text {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(MacSettingsTheme.accent)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: Self.suggestionsMaxHeight)
                .background(MacSettingsTheme.controlBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
            }
        }
    }
}
