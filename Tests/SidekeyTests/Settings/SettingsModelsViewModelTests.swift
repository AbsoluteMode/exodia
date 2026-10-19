import XCTest
@testable import Sidekey

@MainActor
final class SettingsModelsViewModelTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "models.vm.\(UUID().uuidString)")!
    }

    /// Builds a view model over isolated prefs. `isAppleSilicon` drives the
    /// prefs default for a route the user never chose: none on Apple Silicon
    /// (where the removed on-device models used to be the default) and BYOK
    /// everywhere else. Pass `transcriptionLevel` / `llmLevel` to start from a
    /// persisted route instead of the fresh-install default.
    private func makeVM(
        isAppleSilicon: Bool = true,
        transcriptionLevel: TranscriptionIsolationLevel? = nil,
        llmLevel: LLMIsolationLevel? = nil,
        probeSucceeds: Bool = true,
        keyStore: BYOKKeyStore = .inMemory(),
        llmKeyStore: any OpenRouterLLMKeyStoring = ModelsFakeOpenRouterKeyStore(),
        customLLMKeyStore: any OpenRouterLLMKeyStoring = ModelsFakeOpenRouterKeyStore(),
        openRouterClient: any OpenRouterLLMClienting = ModelsFakeOpenRouterClient(),
        makeProbe: ((BYOKProvider, String, String?, String) -> BYOKConnectionProbing)? = nil
    ) -> (SettingsModelsViewModel, SelfKeyPreferences) {
        let prefs = SelfKeyPreferences(defaults: makeDefaults(), isAppleSilicon: isAppleSilicon)
        if let transcriptionLevel { prefs.transcriptionLevel = transcriptionLevel }
        if let llmLevel { prefs.llmLevel = llmLevel }
        let probeFactory: (BYOKProvider, String, String?, String) -> BYOKConnectionProbing
        if let makeProbe {
            probeFactory = makeProbe
        } else {
            probeFactory = { _, _, _, _ in StubProbe(succeeds: probeSucceeds) }
        }
        let vm = SettingsModelsViewModel(
            prefs: prefs,
            keyStore: keyStore,
            llmKeyStore: llmKeyStore,
            customLLMKeyStore: customLLMKeyStore,
            openRouterClient: openRouterClient,
            makeProbe: probeFactory
        )
        return (vm, prefs)
    }

    /// Keys live in an in-memory store so the suite never reads, writes, or
    /// prompts for the user's real Keychain items.
    private func withInMemoryKeyStore(_ provider: BYOKProvider, _ body: (BYOKKeyStore) throws -> Void) rethrows {
        _ = provider
        try body(.inMemory())
    }

    // MARK: - Defaults

    func testFreshInstallDefaultsFollowHardware() {
        // Apple Silicon used to default to the removed on-device models, so a
        // fresh install there starts with no route chosen.
        let (appleSilicon, _) = makeVM(isAppleSilicon: true)
        XCTAssertNil(appleSilicon.approvedLevel)
        XCTAssertNil(appleSilicon.approvedLLMLevel)
        XCTAssertEqual(appleSilicon.llmLevel, .yourKey)
        // BYOK default is soniox now (OpenAI dropped from the picker).
        XCTAssertEqual(appleSilicon.provider, .soniox)
        XCTAssertEqual(appleSilicon.selfHostedModel, "gpt-4o-transcribe")

        let (intel, _) = makeVM(isAppleSilicon: false)
        XCTAssertEqual(intel.approvedLevel, .yourKey)
        XCTAssertEqual(intel.llmLevel, .yourKey)
        XCTAssertEqual(intel.approvedLLMLevel, .yourKey)
    }

    func testSelectedModelLoadsProviderDefault() {
        let (vm, _) = makeVM()  // provider defaults to soniox
        XCTAssertEqual(vm.selectedModel, "stt-rt-v5")
    }

    func testProviderChangeLoadsThatProvidersModelAndList() {
        let (vm, _) = makeVM()
        vm.provider = .openAI
        vm.providerChanged()
        XCTAssertEqual(vm.selectedModel, "gpt-4o-transcribe")
        XCTAssertEqual(vm.models, ["gpt-4o-transcribe", "gpt-4o-mini-transcribe"])
    }

    func testSavePersistsSelectedModelPerProvider() {
        withInMemoryKeyStore(.openAI) { kc in
            let (vm, prefs) = makeVM(keyStore: kc)
            vm.provider = .openAI
            vm.selectedModel = "gpt-4o-mini-transcribe"
            vm.save()
            XCTAssertEqual(prefs.transcriptionModel(for: .openAI), "gpt-4o-mini-transcribe")
        }
    }

    // MARK: - STT save

    func testSaveWithoutChosenProviderKeepsDropOff() throws {
        // Editing fields never turns on a provider: only a validated save does.
        let keyStore = BYOKKeyStore.inMemory()
        let (vm, prefs) = makeVM(keyStore: keyStore)
        vm.provider = .deepgram
        vm.providerChanged()
        vm.apiKeyInput = "dg-key"

        vm.save()

        XCTAssertNil(prefs.transcriptionLevel)
        XCTAssertNil(vm.approvedLevel)
        XCTAssertEqual(prefs.selectedProvider, .deepgram)
        XCTAssertEqual(try keyStore.read(for: .deepgram), "dg-key")
    }

    func testSaveCurrentSelectionRequiresApiKeyAndLeavesProviderUnchosen() async {
        let (vm, prefs) = makeVM()
        vm.apiKeyInput = "   "

        await vm.saveCurrentSelection()

        XCTAssertNil(prefs.transcriptionLevel)
        XCTAssertNil(vm.approvedLevel)
        XCTAssertEqual(vm.connectionStatus, .failed("Enter an API key"))
    }

    func testSaveCurrentSelectionRequiresSuccessfulValidation() async {
        let (vm, prefs) = makeVM(probeSucceeds: false)
        vm.apiKeyInput = "sk-test"

        await vm.saveCurrentSelection()

        XCTAssertNil(prefs.transcriptionLevel)
        XCTAssertNil(vm.approvedLevel)
        XCTAssertEqual(vm.connectionStatus, .failed("Could not reach provider"))
    }

    func testSaveCurrentSelectionPersistsYourKeyAfterValidation() async throws {
        let keyStore = BYOKKeyStore.inMemory()

        let (vm, prefs) = makeVM(keyStore: keyStore)
        vm.provider = .openAI
        vm.apiKeyInput = "sk-approved"

        await vm.saveCurrentSelection()

        XCTAssertEqual(prefs.transcriptionLevel, .yourKey)
        XCTAssertEqual(vm.approvedLevel, .yourKey)
        XCTAssertEqual(vm.connectionStatus, .ok)
        XCTAssertEqual(try keyStore.read(for: .openAI), "sk-approved")
    }

    func testSaveCurrentSelectionValidatesSelectedProviderAndModel() async {
        final class Capture {
            var provider: BYOKProvider?
            var model: String?
        }
        let capture = Capture()
        let keyStore = BYOKKeyStore.inMemory()

        let (vm, _) = makeVM(
            keyStore: keyStore,
            makeProbe: { provider, _, _, model in
                capture.provider = provider
                capture.model = model
                return StubProbe(succeeds: true)
            }
        )
        vm.provider = .deepgram
        vm.selectedModel = "nova-3"
        vm.apiKeyInput = "dg-key"

        await vm.saveCurrentSelection()

        XCTAssertEqual(capture.provider, .deepgram)
        XCTAssertEqual(capture.model, "nova-3")
    }

    func testSaveKeyPersistsToKeychainAndPrefs() throws {
        try withInMemoryKeyStore(.openAI) { keyStore in
            let (vm, _) = makeVM(keyStore: keyStore)
            vm.provider = .openAI
            vm.apiKeyInput = "sk-abc"
            vm.save()
            XCTAssertEqual(try keyStore.read(for: .openAI), "sk-abc")
        }
    }

    func testTestConnectionSuccess() async {
        let (vm, _) = makeVM()
        vm.provider = .openAI
        vm.apiKeyInput = "sk-x"
        await vm.testConnection()
        XCTAssertEqual(vm.connectionStatus, .ok)
    }

    func testTestConnectionFailureWithoutKey() async {
        let (vm, _) = makeVM()
        vm.provider = .openAI
        vm.apiKeyInput = ""
        await vm.testConnection()
        if case .failed = vm.connectionStatus {} else { XCTFail("expected failed") }
    }

    // MARK: - LLM BYOK (OpenRouter)

    func testOpenRouterModelSuggestionsFilterAndKeepTypedCustomModel() {
        let models = [
            OpenRouterModelOption(id: "openai/gpt-4o-mini", name: "GPT-4o mini"),
            OpenRouterModelOption(id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4"),
            OpenRouterModelOption(id: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash"),
        ]

        let filtered = SettingsModelsViewModel.filteredOpenRouterModels(
            query: "claude",
            models: models,
            limit: 8
        )

        XCTAssertEqual(filtered.first, OpenRouterModelOption(id: "claude", name: "Custom model"))
        XCTAssertEqual(filtered.dropFirst().map(\.id), ["anthropic/claude-sonnet-4"])
    }

    func testOpenRouterModelSuggestionsBrowseFromSelectedModel() {
        let models = [
            OpenRouterModelOption(id: "openai/gpt-4o-mini", name: "GPT-4o mini"),
            OpenRouterModelOption(id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4"),
            OpenRouterModelOption(id: "google/gemini-3.5-pro", name: "Gemini 3.5 Pro"),
        ]

        let filtered = SettingsModelsViewModel.filteredOpenRouterModels(
            query: "openai/gpt-4o-mini",
            models: models,
            limit: 8
        )

        XCTAssertEqual(filtered.first?.id, "openai/gpt-4o-mini")
        XCTAssertTrue(filtered.contains { $0.id == "google/gemini-3.5-pro" })
    }

    func testOpenRouterFallbackSuggestionsStartWithExplicitModelNotAutoRouter() {
        let filtered = SettingsModelsViewModel.filteredOpenRouterModels(
            query: "",
            models: [],
            limit: 3
        )

        XCTAssertEqual(filtered.first?.id, "openai/gpt-4o-mini")
        XCTAssertFalse(filtered.prefix(3).contains { $0.id == "openrouter/auto" })
    }

    func testSaveCurrentLLMSelectionPersistsOpenRouterAfterValidation() async throws {
        let llmKeyStore = ModelsFakeOpenRouterKeyStore()
        let openRouter = ModelsFakeOpenRouterClient(models: [
            OpenRouterModelOption(id: "openai/gpt-4o-mini", name: "GPT-4o mini")
        ])
        let (vm, prefs) = makeVM(llmKeyStore: llmKeyStore, openRouterClient: openRouter)

        vm.selectLLMLevel(.yourKey)
        vm.openRouterModel = "openai/gpt-4o-mini"
        vm.openRouterAPIKeyInput = "or-key"

        await vm.saveCurrentLLMSelection()

        XCTAssertEqual(prefs.llmLevel, .yourKey)
        XCTAssertEqual(prefs.openRouterModel, "openai/gpt-4o-mini")
        XCTAssertEqual(try llmKeyStore.read(), "or-key")
        XCTAssertEqual(vm.llmConnectionStatus, .ok)
        XCTAssertEqual(openRouter.lastListAPIKey, "or-key")
    }

    func testSaveCurrentLLMSelectionPersistsCustomEndpointAfterValidation() async throws {
        let customKeyStore = ModelsFakeOpenRouterKeyStore()
        let openRouter = ModelsFakeOpenRouterClient(models: [
            OpenRouterModelOption(id: "llama/local", name: "Llama Local")
        ])
        let (vm, prefs) = makeVM(customLLMKeyStore: customKeyStore, openRouterClient: openRouter)

        vm.selectLLMLevel(.custom)
        vm.customLLMBaseURL = " http://localhost:8000/v1 "
        vm.customLLMModel = "llama/local"
        vm.customLLMAPIKeyInput = "internal-key"

        await vm.saveCurrentLLMSelection()

        XCTAssertEqual(prefs.llmLevel, .custom)
        XCTAssertEqual(prefs.customLLMBaseURL, "http://localhost:8000/v1")
        XCTAssertEqual(prefs.customLLMModel, "llama/local")
        XCTAssertEqual(try customKeyStore.read(), "internal-key")
        XCTAssertEqual(vm.llmConnectionStatus, .ok)
        XCTAssertEqual(openRouter.lastListEndpoint?.baseURL.absoluteString, "http://localhost:8000/v1")
        XCTAssertEqual(openRouter.lastListEndpoint?.apiKey, "internal-key")
        XCTAssertEqual(openRouter.lastListEndpoint?.requiresAPIKey, false)
    }

    func testCustomOpenAICompatibleLLMKeyIsOptional() async throws {
        let customKeyStore = ModelsFakeOpenRouterKeyStore()
        let openRouter = ModelsFakeOpenRouterClient(models: [
            OpenRouterModelOption(id: "llama/local", name: "Llama Local")
        ])
        let (vm, prefs) = makeVM(customLLMKeyStore: customKeyStore, openRouterClient: openRouter)

        vm.selectLLMLevel(.custom)
        vm.customLLMBaseURL = "http://localhost:8000/v1"
        vm.customLLMModel = "llama/local"
        vm.customLLMAPIKeyInput = "   "

        await vm.saveCurrentLLMSelection()

        XCTAssertEqual(prefs.llmLevel, .custom)
        XCTAssertNil(try customKeyStore.read())
        XCTAssertNil(openRouter.lastListEndpoint?.apiKey)
        XCTAssertEqual(vm.llmConnectionStatus, .ok)
    }

    func testSavingCustomLLMDoesNotDeleteSavedOpenRouterKey() async throws {
        let llmKeyStore = ModelsFakeOpenRouterKeyStore()
        try llmKeyStore.save(key: "or-existing")
        let (vm, prefs) = makeVM(llmLevel: .yourKey, llmKeyStore: llmKeyStore)

        // An empty key field must never delete the stored key when the user
        // commits a different route.
        vm.openRouterAPIKeyInput = ""
        vm.selectLLMLevel(.custom)
        vm.customLLMBaseURL = "http://localhost:8000/v1"
        await vm.saveCurrentLLMSelection()

        XCTAssertEqual(prefs.llmLevel, .custom)
        XCTAssertEqual(try llmKeyStore.read(), "or-existing")
    }

    // MARK: - LLM route selection and save

    func testPersistedCustomRouteHydratesPicker() {
        let (vm, _) = makeVM(llmLevel: .custom)

        XCTAssertEqual(vm.llmLevel, .custom)
        XCTAssertEqual(vm.approvedLLMLevel, .custom)
    }

    func testSelectingLLMRouteDoesNotPersistUntilSaved() {
        let (vm, prefs) = makeVM(llmLevel: .yourKey)
        vm.selectLLMLevel(.custom)

        XCTAssertEqual(vm.llmLevel, .custom)
        XCTAssertEqual(prefs.llmLevel, .yourKey)  // selection alone never persists
        XCTAssertEqual(vm.approvedLLMLevel, .yourKey)
    }

    func testFailedLLMValidationLeavesRouteUnchosen() async {
        let (vm, prefs) = makeVM()
        vm.openRouterAPIKeyInput = ""

        await vm.saveCurrentLLMSelection()

        XCTAssertNil(prefs.llmLevel)
        XCTAssertNil(vm.approvedLLMLevel)
        XCTAssertEqual(vm.llmConnectionStatus, .failed("Enter an OpenRouter API key"))
    }

    func testSaveLLMWithoutChosenRouteKeepsCleanupOff() throws {
        // Editing fields never chooses a route: only a validated save does.
        let llmKeyStore = ModelsFakeOpenRouterKeyStore()
        let (vm, prefs) = makeVM(llmKeyStore: llmKeyStore)
        vm.openRouterAPIKeyInput = "or-key"
        vm.openRouterModel = "openai/gpt-4o-mini"

        vm.saveLLM()

        XCTAssertNil(prefs.llmLevel)
        XCTAssertNil(vm.approvedLLMLevel)
        XCTAssertEqual(try llmKeyStore.read(), "or-key")
        XCTAssertEqual(prefs.openRouterModel, "openai/gpt-4o-mini")
    }

    func testSaveLLMKeepsCommittedRouteWhenPickerMoved() {
        let (vm, prefs) = makeVM(llmLevel: .custom)
        vm.selectLLMLevel(.yourKey)

        vm.saveLLM()

        XCTAssertEqual(prefs.llmLevel, .custom)
    }

    func testLLMSaveCommitsTheRouteThatWasValidated() async {
        let client = GatedOpenRouterClient()
        let (vm, prefs) = makeVM(openRouterClient: client)
        vm.openRouterAPIKeyInput = "or-key"

        let save = Task { await vm.saveCurrentLLMSelection() }
        for await _ in client.started { break }
        // The picker moves to an unvalidated route while OpenRouter is checked.
        vm.selectLLMLevel(.custom)
        client.open()
        let saved = await save.value

        XCTAssertTrue(saved)
        XCTAssertEqual(prefs.llmLevel, .yourKey)
        XCTAssertEqual(vm.approvedLLMLevel, .yourKey)
    }
}

/// Minimal probe stub the test injects.
final class StubProbe: BYOKConnectionProbing {
    let succeeds: Bool
    init(succeeds: Bool) { self.succeeds = succeeds }
    func probe() async -> Bool { succeeds }
}

private final class ModelsFakeOpenRouterClient: OpenRouterLLMClienting {
    var models: [OpenRouterModelOption]
    private(set) var lastListEndpoint: OpenAICompatibleLLMEndpoint?
    var lastListAPIKey: String? { lastListEndpoint?.apiKey }

    init(models: [OpenRouterModelOption] = OpenRouterModelOption.fallback) {
        self.models = models
    }

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] {
        lastListEndpoint = endpoint
        return models
    }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        "unused"
    }
}

private final class ModelsFakeOpenRouterKeyStore: OpenRouterLLMKeyStoring {
    var key: String?
    var failWrites = false

    func save(key: String) throws {
        if failWrites { throw NSError(domain: "TestKeychain", code: 1) }
        self.key = key
    }

    func read() throws -> String? {
        key
    }

    func delete() throws {
        key = nil
    }
}

/// Holds model listing open until the test releases it, so the test can move
/// the picker while a save is validating.
private final class GatedOpenRouterClient: OpenRouterLLMClienting {
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation

    init() {
        var startedContinuation: AsyncStream<Void>.Continuation!
        started = AsyncStream { startedContinuation = $0 }
        self.startedContinuation = startedContinuation
        var gateContinuation: AsyncStream<Void>.Continuation!
        gate = AsyncStream { gateContinuation = $0 }
        self.gateContinuation = gateContinuation
    }

    func open() {
        gateContinuation.yield()
    }

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] {
        startedContinuation.yield()
        for await _ in gate { break }
        return OpenRouterModelOption.fallback
    }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        "unused"
    }
}
