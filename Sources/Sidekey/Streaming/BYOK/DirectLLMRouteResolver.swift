import Foundation

struct DirectLLMRoute {
    let endpoint: OpenAICompatibleLLMEndpoint
    let model: String
}

extension DirectLLMRoute: Equatable {
    static func == (lhs: DirectLLMRoute, rhs: DirectLLMRoute) -> Bool {
        lhs.model == rhs.model && lhs.endpoint == rhs.endpoint
    }
}

/// Resolves the user-selected LLM route for cleanup/workflows. OpenRouter and
/// custom OpenAI-compatible endpoints return a concrete `/chat/completions`
/// target; without a chosen level there is no route.
struct DirectLLMRouteResolver {
    let prefs: SelfKeyPreferences
    let llmKeyStore: any OpenRouterLLMKeyStoring
    let customLLMKeyStore: any OpenRouterLLMKeyStoring

    init(
        prefs: SelfKeyPreferences,
        llmKeyStore: any OpenRouterLLMKeyStoring = OpenRouterLLMKeyStore(),
        customLLMKeyStore: any OpenRouterLLMKeyStoring = CustomLLMKeyStore()
    ) {
        self.prefs = prefs
        self.llmKeyStore = llmKeyStore
        self.customLLMKeyStore = customLLMKeyStore
    }

    @MainActor
    static func live(
        llmKeyStore: any OpenRouterLLMKeyStoring = OpenRouterLLMKeyStore(),
        customLLMKeyStore: any OpenRouterLLMKeyStoring = CustomLLMKeyStore()
    ) -> DirectLLMRouteResolver {
        DirectLLMRouteResolver(
            prefs: .shared,
            llmKeyStore: llmKeyStore,
            customLLMKeyStore: customLLMKeyStore
        )
    }

    /// The direct route (OpenRouter / custom), or nil when no LLM level is
    /// chosen. Throws (`OpenRouterLLMError`) when the chosen route lacks its
    /// key / base URL. A stored OpenRouter key alone (Settings -> Agents
    /// shares it) never chooses a route.
    func routeIfEnabled() async throws -> DirectLLMRoute? {
        let settings = await resolvedSettings()
        guard let level = settings.level else { return nil }
        return try directRoute(for: level, settings: settings)
    }

    private struct ResolvedSettings {
        let level: LLMIsolationLevel?
        let openRouterModel: String
        let customBaseURL: String?
        let customModel: String
        let defaultOpenRouterModel: String
        let defaultCustomLLMModel: String
    }

    private func resolvedSettings() async -> ResolvedSettings {
        await MainActor.run {
            ResolvedSettings(
                level: prefs.llmLevel,
                openRouterModel: prefs.openRouterModel,
                customBaseURL: prefs.customLLMBaseURL,
                customModel: prefs.customLLMModel,
                defaultOpenRouterModel: SelfKeyPreferences.defaultOpenRouterModel,
                defaultCustomLLMModel: SelfKeyPreferences.defaultCustomLLMModel
            )
        }
    }

    private func directRoute(for level: LLMIsolationLevel, settings: ResolvedSettings) throws -> DirectLLMRoute {
        switch level {
        case .yourKey:
            let key = try llmKeyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key, !key.isEmpty else { throw OpenRouterLLMError.missingKey }
            let model = settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return DirectLLMRoute(
                endpoint: .openRouter(apiKey: key),
                model: model.isEmpty ? settings.defaultOpenRouterModel : model
            )
        case .custom:
            let rawBaseURL = settings.customBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !rawBaseURL.isEmpty else { throw OpenRouterLLMError.missingBaseURL }
            guard let baseURL = URL(string: rawBaseURL),
                  let scheme = baseURL.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  baseURL.host != nil
            else {
                throw OpenRouterLLMError.invalidBaseURL(rawBaseURL)
            }
            let rawKey = try customLLMKeyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rawKey?.isEmpty == false ? rawKey : nil
            let model = settings.customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return DirectLLMRoute(
                endpoint: .custom(baseURL: baseURL, apiKey: key),
                model: model.isEmpty ? settings.defaultCustomLLMModel : model
            )
        }
    }
}
