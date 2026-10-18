import XCTest
@testable import Sidekey

/// On-device models were removed. A user whose audio and text stayed on this
/// Mac, by choosing Local or by never choosing on Apple Silicon (where Local
/// was the default), must not start sending them to a provider until they
/// choose one in Settings -> Models, even when a provider key is stored.
@MainActor
final class RetiredLocalRouteTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "retired.local.\(UUID().uuidString)")!
    }

    private func retiredLocalDefaults() -> UserDefaults {
        let defaults = makeDefaults()
        defaults.set("local", forKey: "sidekey.models.transcriptionLevel")
        defaults.set("local", forKey: "sidekey.models.llmLevel")
        return defaults
    }

    func test_storedLocalLevels_areNotConfigured_onAnyHardware() {
        for isAppleSilicon in [true, false] {
            let prefs = SelfKeyPreferences(defaults: retiredLocalDefaults(), isAppleSilicon: isAppleSilicon)
            XCTAssertNil(prefs.transcriptionLevel, "appleSilicon=\(isAppleSilicon)")
            XCTAssertNil(prefs.llmLevel, "appleSilicon=\(isAppleSilicon)")
        }
    }

    func test_noStoredLevel_onAppleSilicon_isNotConfigured() {
        let prefs = SelfKeyPreferences(defaults: makeDefaults(), isAppleSilicon: true)
        XCTAssertNil(prefs.transcriptionLevel)
        XCTAssertNil(prefs.llmLevel)
    }

    func test_noStoredLevel_onIntel_staysYourKey() {
        let prefs = SelfKeyPreferences(defaults: makeDefaults(), isAppleSilicon: false)
        XCTAssertEqual(prefs.transcriptionLevel, .yourKey)
        XCTAssertEqual(prefs.llmLevel, .yourKey)
    }

    func test_drop_withRetiredLocal_doesNotUseStoredProviderKey() throws {
        let prefs = SelfKeyPreferences(defaults: retiredLocalDefaults(), isAppleSilicon: true)
        prefs.selectedProvider = .soniox
        let keys = BYOKKeyStore.inMemory()
        try keys.save(key: "soniox-key", for: .soniox)
        let factory = TranscriptionSessionFactory(
            prefs: prefs,
            keyStore: keys,
            vocab: VocabularyCache(defaults: makeDefaults())
        )
        XCTAssertThrowsError(try factory.make(language: "en")) { error in
            XCTAssertEqual(error as? TranscriptionFactoryError, .notConfigured)
        }
    }

    func test_cleanup_withoutChoice_doesNotUseStoredOpenRouterKey() async throws {
        // The OpenRouter key may come from Settings -> Agents; it does not
        // choose where Drop cleanup or meeting notes go.
        for defaults in [retiredLocalDefaults(), makeDefaults()] {
            let prefs = SelfKeyPreferences(defaults: defaults, isAppleSilicon: true)
            let llmKeys = StubLLMKeyStore(key: "or-key")
            let client = SpyLLMClient()
            let processor = PostProcessor(
                prefs: prefs,
                llmKeyStore: llmKeys,
                customLLMKeyStore: StubLLMKeyStore(key: nil),
                openRouterClient: client
            )
            do {
                let cleaned = try await processor.process("raw", targetApp: nil)
                XCTFail("expected no cleanup, got \(cleaned)")
            } catch let error as OpenRouterLLMError {
                XCTAssertEqual(error, .notConfigured)
            }
            XCTAssertEqual(client.completeCalls, 0)

            let resolver = DirectLLMRouteResolver(
                prefs: prefs,
                llmKeyStore: llmKeys,
                customLLMKeyStore: StubLLMKeyStore(key: nil)
            )
            let meetingRoute = try await resolver.routeIfEnabled()
            XCTAssertNil(meetingRoute)
        }
    }

    func test_meetings_withRetiredLocal_areNotProcessedByProviders() throws {
        let prefs = SelfKeyPreferences(defaults: retiredLocalDefaults(), isAppleSilicon: true)
        prefs.selectedProvider = .soniox
        let keys = BYOKKeyStore.inMemory()
        try keys.save(key: "soniox-key", for: .soniox)
        let processor = MeetingBYOKProcessor(
            prefs: prefs,
            keyStore: keys,
            vocab: VocabularyCache(defaults: makeDefaults()),
            llmRouteResolver: DirectLLMRouteResolver(
                prefs: prefs,
                llmKeyStore: StubLLMKeyStore(key: "or-key"),
                customLLMKeyStore: StubLLMKeyStore(key: nil)
            )
        )
        XCTAssertFalse(processor.shouldProcessDirectly())
    }

    func test_choosingYourKey_afterRetiredLocal_buildsProviderSession() throws {
        let prefs = SelfKeyPreferences(defaults: retiredLocalDefaults(), isAppleSilicon: true)
        prefs.selectedProvider = .soniox
        prefs.transcriptionLevel = .yourKey
        let keys = BYOKKeyStore.inMemory()
        try keys.save(key: "soniox-key", for: .soniox)
        let factory = TranscriptionSessionFactory(
            prefs: prefs,
            keyStore: keys,
            vocab: VocabularyCache(defaults: makeDefaults())
        )
        XCTAssertTrue(try factory.make(language: "en") is DirectProviderStreamingSession)
    }
}

private final class StubLLMKeyStore: OpenRouterLLMKeyStoring {
    var key: String?
    init(key: String?) { self.key = key }
    func save(key: String) throws { self.key = key }
    func read() throws -> String? { key }
    func delete() throws { key = nil }
}

private final class SpyLLMClient: OpenRouterLLMClienting {
    private(set) var completeCalls = 0

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] { [] }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        completeCalls += 1
        return "cleaned"
    }
}
