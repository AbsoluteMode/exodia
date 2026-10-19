// Sources/Sidekey/Settings/SettingsModelsViewModel.swift
import Foundation

/// Abstracts the "can we reach the provider with this key/config" check so the
/// view model is testable without a network call.
protocol BYOKConnectionProbing {
    func probe() async -> Bool
}

enum BYOKConnectionStatus: Equatable {
    case idle
    case testing
    case ok
    case failed(String)
}

@MainActor
final class SettingsModelsViewModel: ObservableObject {
    @Published var provider: BYOKProvider
    @Published var selfHostedBaseURL: String
    @Published var selfHostedModel: String
    /// Selected realtime model for the current provider (picker value). For
    /// `selfHosted` the free-text `selfHostedModel` is used instead.
    @Published var selectedModel: String
    @Published var apiKeyInput: String
    @Published private(set) var connectionStatus: BYOKConnectionStatus = .idle
    /// Committed transcription level (persisted). `nil` = no provider saved
    /// yet, so Drop stays off until the user saves one.
    @Published private(set) var approvedLevel: TranscriptionIsolationLevel?

    /// LLM route shown in the panel: `.yourKey` = OpenRouter with the user's
    /// key, `.custom` = a user-hosted OpenAI-compatible endpoint. Defaults to
    /// OpenRouter while no route is saved.
    @Published var llmLevel: LLMIsolationLevel
    /// Editable OpenRouter model id. The UI suggests remote models, but any
    /// text is accepted so newly released models can be used immediately.
    @Published var openRouterModel: String
    @Published var openRouterAPIKeyInput: String
    @Published var customLLMBaseURL: String
    @Published var customLLMModel: String
    @Published var customLLMAPIKeyInput: String
    @Published private(set) var llmConnectionStatus: BYOKConnectionStatus = .idle
    /// Committed LLM level (persisted). Mirrors `approvedLevel` on the STT
    /// side; `nil` = no route saved, so cleanup returns the no-LLM output.
    @Published private(set) var approvedLLMLevel: LLMIsolationLevel?
    @Published private(set) var openRouterModels: [OpenRouterModelOption]
    @Published private(set) var customLLMModels: [OpenRouterModelOption]

    /// Models offered in the picker for the current provider (empty for
    /// self-hosted, which is free-text).
    var models: [String] { provider.availableTranscriptionModels }

    private var prefs: SelfKeyPreferences
    private let keyStore: BYOKKeyStore
    /// (provider, apiKey, baseURL?, model) -> provider reachability probe.
    private let makeProbe: (BYOKProvider, String, String?, String) -> BYOKConnectionProbing
    private let llmKeyStore: any OpenRouterLLMKeyStoring
    private let customLLMKeyStore: any OpenRouterLLMKeyStoring
    private let openRouterClient: any OpenRouterLLMClienting

    private static let customLLMModelFallback: [OpenRouterModelOption] = [
        OpenRouterModelOption(id: SelfKeyPreferences.defaultCustomLLMModel, name: "Custom model"),
    ]

    init(
        prefs: SelfKeyPreferences = .shared,
        keyStore: BYOKKeyStore = BYOKKeyStore(),
        llmKeyStore: any OpenRouterLLMKeyStoring = OpenRouterLLMKeyStore(),
        customLLMKeyStore: any OpenRouterLLMKeyStoring = CustomLLMKeyStore(),
        openRouterClient: any OpenRouterLLMClienting = OpenRouterLLMClient(),
        makeProbe: @escaping (BYOKProvider, String, String?, String) -> BYOKConnectionProbing = { provider, key, baseURL, model in
            BYOKProviderConnectionProbe(provider: provider, apiKey: key, baseURL: baseURL, model: model)
        }
    ) {
        self.prefs = prefs
        self.keyStore = keyStore
        self.llmKeyStore = llmKeyStore
        self.customLLMKeyStore = customLLMKeyStore
        self.openRouterClient = openRouterClient
        self.makeProbe = makeProbe
        self.approvedLevel = prefs.transcriptionLevel
        self.provider = prefs.selectedProvider
        self.selfHostedBaseURL = prefs.selfHostedBaseURL ?? ""
        self.selfHostedModel = prefs.selfHostedModel
        self.selectedModel = prefs.transcriptionModel(for: prefs.selectedProvider)
        self.apiKeyInput = (try? keyStore.read(for: prefs.selectedProvider)) ?? ""
        self.llmLevel = prefs.llmLevel ?? .yourKey
        self.approvedLLMLevel = prefs.llmLevel
        self.openRouterModel = prefs.openRouterModel
        self.openRouterAPIKeyInput = (try? llmKeyStore.read()) ?? ""
        self.customLLMBaseURL = prefs.customLLMBaseURL ?? ""
        self.customLLMModel = prefs.customLLMModel
        self.customLLMAPIKeyInput = (try? customLLMKeyStore.read()) ?? ""
        self.openRouterModels = OpenRouterModelOption.fallback
        self.customLLMModels = Self.customLLMModelFallback
    }

    /// Validate the selected provider with the entered key, then commit it as
    /// the transcription route. This is the only way a level gets chosen.
    @discardableResult
    func saveCurrentSelection() async -> Bool {
        guard await validateBYOKConnection() else { return false }
        guard persistSettings(committedLevel: .yourKey) else { return false }
        approvedLevel = .yourKey
        connectionStatus = .ok
        return true
    }

    func selectLLMLevel(_ level: LLMIsolationLevel) {
        guard llmLevel != level else { return }
        llmLevel = level
        llmConnectionStatus = .idle
    }

    @discardableResult
    func saveCurrentLLMSelection() async -> Bool {
        // Commit the route that was validated, even if the picker moves while
        // the check is in flight.
        let level = llmLevel
        switch level {
        case .yourKey:
            guard await validateOpenRouterConnection() else { return false }
        case .custom:
            guard await validateCustomLLMConnection() else { return false }
        }
        guard persistLLMSettings(committedLevel: level) else { return false }
        approvedLLMLevel = level
        llmConnectionStatus = .ok
        return true
    }

    /// Persist the edited LLM fields under the committed route. Without one
    /// the route stays unchosen.
    func saveLLM() {
        persistLLMSettings(committedLevel: prefs.llmLevel)
    }

    func testLLMConnection() async {
        switch llmLevel {
        case .yourKey:
            _ = await validateOpenRouterConnection()
        case .custom:
            _ = await validateCustomLLMConnection()
        }
    }

    func loadOpenRouterModelsIfNeeded() async {
        guard openRouterModels == OpenRouterModelOption.fallback else { return }
        await refreshOpenRouterModels(silent: true)
    }

    func refreshOpenRouterModels() async {
        await refreshOpenRouterModels(silent: false)
    }

    func loadCustomLLMModelsIfNeeded() async {
        guard customLLMModels == Self.customLLMModelFallback else { return }
        await refreshCustomLLMModels(silent: true)
    }

    func refreshCustomLLMModels() async {
        await refreshCustomLLMModels(silent: false)
    }

    var openRouterModelSuggestions: [OpenRouterModelOption] {
        Self.filteredOpenRouterModels(query: openRouterModel, models: openRouterModels, limit: .max)
    }

    var customLLMModelSuggestions: [OpenRouterModelOption] {
        Self.filteredOpenRouterModels(query: customLLMModel, models: customLLMModels, limit: .max)
    }

    static func filteredOpenRouterModels(
        query: String,
        models: [OpenRouterModelOption],
        limit: Int
    ) -> [OpenRouterModelOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = models.isEmpty ? OpenRouterModelOption.fallback : models
        let selected: [OpenRouterModelOption]
        if trimmed.isEmpty {
            selected = Array(pool.prefix(limit))
        } else if let exact = pool.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            let remaining = pool.filter { $0.id != exact.id }
            selected = [exact] + Array(remaining.prefix(max(0, limit - 1)))
        } else {
            let q = trimmed.lowercased()
            let scored = pool.compactMap { option -> (Int, OpenRouterModelOption)? in
                let id = option.id.lowercased()
                let name = option.name.lowercased()
                if id == q { return (0, option) }
                if id.hasPrefix(q) { return (1, option) }
                if name.hasPrefix(q) { return (2, option) }
                if id.contains(q) { return (3, option) }
                if name.contains(q) { return (4, option) }
                return nil
            }
            selected = scored
                .sorted { lhs, rhs in
                    lhs.0 == rhs.0 ? lhs.1.id < rhs.1.id : lhs.0 < rhs.0
                }
                .prefix(limit)
                .map(\.1)
        }

        guard !trimmed.isEmpty, !selected.contains(where: { $0.id == trimmed }) else {
            return selected
        }
        return [OpenRouterModelOption(id: trimmed, name: "Custom model")] + selected
    }

    /// Reload the key + model fields when the provider selection changes.
    func providerChanged() {
        apiKeyInput = (try? keyStore.read(for: provider)) ?? ""
        selectedModel = prefs.transcriptionModel(for: provider)
        connectionStatus = .idle
    }

    /// Persist the edited provider fields under the committed level. Without
    /// one the level stays unchosen: editing fields never turns on a provider.
    func save() {
        persistSettings(committedLevel: approvedLevel)
    }

    @discardableResult
    private func persistSettings(committedLevel: TranscriptionIsolationLevel?) -> Bool {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty { try keyStore.delete(for: provider) }
            else { try keyStore.save(key: trimmed, for: provider) }
        } catch {
            setConnectionFailure("Could not save API key in Keychain")
            return false
        }
        if let committedLevel { prefs.transcriptionLevel = committedLevel }
        prefs.selectedProvider = provider
        let trimmedBaseURL = selfHostedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSelfHostedModel = selfHostedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.selfHostedBaseURL = trimmedBaseURL.isEmpty ? nil : trimmedBaseURL
        prefs.selfHostedModel = trimmedSelfHostedModel.isEmpty ? SelfKeyPreferences.defaultModel : trimmedSelfHostedModel
        // Self-hosted persists via `selfHostedModel` above; every other provider
        // stores its picker selection per-provider.
        if provider != .selfHosted { prefs.setTranscriptionModel(selectedModel, for: provider) }
        return true
    }

    @discardableResult
    private func persistLLMSettings(committedLevel: LLMIsolationLevel?) -> Bool {
        let trimmed = openRouterAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCustomKey = customLLMAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !trimmed.isEmpty { try llmKeyStore.save(key: trimmed) }
            if !trimmedCustomKey.isEmpty { try customLLMKeyStore.save(key: trimmedCustomKey) }
        } catch {
            llmConnectionStatus = .failed("Could not save API key in Keychain")
            return false
        }
        if let committedLevel { prefs.llmLevel = committedLevel }
        prefs.openRouterModel = openRouterModel
        prefs.customLLMBaseURL = customLLMBaseURL
        prefs.customLLMModel = customLLMModel
        return true
    }

    func testConnection() async {
        _ = await validateBYOKConnection()
    }

    private func validateBYOKConnection() async -> Bool {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            setConnectionFailure("Enter an API key")
            return false
        }
        let trimmedBaseURL = selfHostedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .selfHosted, trimmedBaseURL.isEmpty {
            setConnectionFailure("Enter a base URL")
            return false
        }
        connectionStatus = .testing
        let baseURL = provider == .selfHosted ? trimmedBaseURL : nil
        let rawModel = provider == .selfHosted ? selfHostedModel : selectedModel
        let trimmedModel = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = trimmedModel.isEmpty ? SelfKeyPreferences.defaultModel : trimmedModel
        let ok = await makeProbe(provider, key, baseURL, model).probe()
        if ok {
            connectionStatus = .ok
        } else {
            setConnectionFailure("Could not reach provider")
        }
        return ok
    }

    private func validateOpenRouterConnection() async -> Bool {
        let key = openRouterAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            llmConnectionStatus = .failed("Enter an OpenRouter API key")
            return false
        }
        let model = openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            llmConnectionStatus = .failed("Enter an OpenRouter model ID")
            return false
        }
        llmConnectionStatus = .testing
        do {
            let models = try await openRouterClient.listModels(apiKey: key)
            mergeOpenRouterModels(models)
            llmConnectionStatus = .ok
            return true
        } catch {
            llmConnectionStatus = .failed("Could not reach OpenRouter")
            return false
        }
    }

    private func validateCustomLLMConnection() async -> Bool {
        let rawBaseURL = customLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawBaseURL.isEmpty else {
            llmConnectionStatus = .failed("Enter a custom LLM Base URL")
            return false
        }
        guard let baseURL = Self.normalizedCustomLLMBaseURL(rawBaseURL) else {
            llmConnectionStatus = .failed("Enter a valid Base URL")
            return false
        }
        let model = customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            llmConnectionStatus = .failed("Enter a custom LLM model ID")
            return false
        }

        llmConnectionStatus = .testing
        do {
            let key = customLLMAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint = OpenAICompatibleLLMEndpoint.custom(
                baseURL: baseURL,
                apiKey: key.isEmpty ? nil : key
            )
            let models = try await openRouterClient.listModels(endpoint: endpoint)
            mergeCustomLLMModels(models)
            llmConnectionStatus = .ok
            return true
        } catch {
            llmConnectionStatus = .failed("Could not reach custom LLM")
            return false
        }
    }

    private func refreshOpenRouterModels(silent: Bool) async {
        do {
            let key = openRouterAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let models = try await openRouterClient.listModels(apiKey: key.isEmpty ? nil : key)
            mergeOpenRouterModels(models)
        } catch {
            if !silent {
                llmConnectionStatus = .failed("Could not load models")
            }
        }
    }

    private func refreshCustomLLMModels(silent: Bool) async {
        let rawBaseURL = customLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = Self.normalizedCustomLLMBaseURL(rawBaseURL) else {
            if !silent {
                llmConnectionStatus = rawBaseURL.isEmpty
                    ? .failed("Enter a custom LLM Base URL")
                    : .failed("Enter a valid Base URL")
            }
            return
        }

        do {
            let key = customLLMAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint = OpenAICompatibleLLMEndpoint.custom(
                baseURL: baseURL,
                apiKey: key.isEmpty ? nil : key
            )
            let models = try await openRouterClient.listModels(endpoint: endpoint)
            mergeCustomLLMModels(models)
        } catch {
            if !silent {
                llmConnectionStatus = .failed("Could not load models")
            }
        }
    }

    private func mergeOpenRouterModels(_ models: [OpenRouterModelOption]) {
        guard !models.isEmpty else { return }
        var seen = Set<String>()
        let merged = (models + OpenRouterModelOption.fallback).filter { option in
            guard !seen.contains(option.id) else { return false }
            seen.insert(option.id)
            return true
        }
        openRouterModels = merged
    }

    private func mergeCustomLLMModels(_ models: [OpenRouterModelOption]) {
        guard !models.isEmpty else { return }
        var seen = Set<String>()
        let merged = (models + Self.customLLMModelFallback).filter { option in
            guard !seen.contains(option.id) else { return false }
            seen.insert(option.id)
            return true
        }
        customLLMModels = merged
    }

    private func setConnectionFailure(_ message: String) {
        connectionStatus = .failed(message)
    }

    private static func normalizedCustomLLMBaseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else {
            return nil
        }
        return url
    }
}

/// Production provider-aware probe used before a BYOK isolation-level change is
/// approved. Provider protocols differ: OpenAI has an immediate server frame;
/// Deepgram/ElevenLabs/Soniox may stay quiet until audio, so a short open
/// socket with no provider error is treated as a successful key/config check.
struct BYOKProviderConnectionProbe: BYOKConnectionProbing {
    let provider: BYOKProvider
    let apiKey: String
    let baseURL: String?
    let model: String

    func probe() async -> Bool {
        switch provider {
        case .openAI, .selfHosted:
            return await OpenAIRealtimeProbe(apiKey: apiKey, baseURL: baseURL, model: model).probe()
        case .deepgram:
            let language = await MainActor.run { PrivacyPreferences.shared.selectedLanguage?.code }
            guard let url = try? DeepgramRealtimeURL.make(model: model, language: language, terms: []) else { return false }
            var request = URLRequest(url: url)
            request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
            return await BYOKWebSocketProbe(request: request).probe()
        case .soniox:
            let request = URLRequest(url: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
            let config: [String: Any] = [
                "api_key": apiKey,
                "model": model,
                "audio_format": "pcm_s16le",
                "sample_rate": 16_000,
                "num_channels": 1,
                "enable_endpoint_detection": false,
            ]
            let data = try? JSONSerialization.data(withJSONObject: config)
            let initialText = data.map { String(decoding: $0, as: UTF8.self) }
            return await BYOKWebSocketProbe(request: request, initialText: initialText).probe()
        case .elevenLabs:
            var request = URLRequest(url: ElevenLabsRealtimeURL.make(model: model, language: nil, terms: []))
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            return await BYOKWebSocketProbe(request: request).probe()
        }
    }
}

private struct BYOKWebSocketProbe: BYOKConnectionProbing {
    let request: URLRequest
    var initialText: String?
    var timeoutNanoseconds: UInt64 = 3_000_000_000

    func probe() async -> Bool {
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        if let initialText {
            do {
                try await task.send(.string(initialText))
            } catch {
                return false
            }
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        return !Self.isProviderError(text)
                    case .data:
                        return true
                    @unknown default:
                        return false
                    }
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func isProviderError(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return text.localizedCaseInsensitiveContains("error")
        }
        if let type = obj["type"] as? String, type.localizedCaseInsensitiveContains("error") {
            return true
        }
        if let messageType = obj["message_type"] as? String,
           messageType.localizedCaseInsensitiveContains("error") {
            return true
        }
        return obj["error"] != nil
    }
}

/// Production connection probe: opens the realtime WebSocket and reads the
/// first server frame. OpenAI sends `session.created` immediately on connect;
/// an auth/endpoint failure surfaces as a receive error or an `error` event.
/// Raced against a timeout so the check ALWAYS resolves (never hangs the UI).
/// `model` is unused here — connectivity + auth are validated by the handshake
/// alone, before any transcription config is sent.
struct OpenAIRealtimeProbe: BYOKConnectionProbing {
    let apiKey: String
    let baseURL: String?
    let model: String

    func probe() async -> Bool {
        guard let url = BYOKRealtimeURL.openAIRealtime(baseURL: baseURL) else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let message = try await task.receive()
                    if case .string(let s) = message,
                       let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                       (obj["type"] as? String) == "error" {
                        return false
                    }
                    return true  // any non-error frame (e.g. session.created) → reachable
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return false  // timeout → unreachable
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
