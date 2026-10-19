import XCTest
@testable import Sidekey

@MainActor
final class PostProcessorOpenRouterTests: XCTestCase {
    private struct Env {
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        func processor(_ client: any OpenRouterLLMClienting) -> PostProcessor {
            PostProcessor(
                llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: routing, keys: keys),
                openRouterClient: client
            )
        }
    }

    private func makeEnv() -> Env {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let box = InMemoryTokenStore.Box()
        return Env(
            routing: AIRoutingStore(defaults: defaults),
            keys: ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        )
    }

    func testOpenRouterBYOKProcessesDirectlyWithoutBackendProcessCall() async throws {
        let env = makeEnv()
        try env.keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "openrouter/auto"), for: .dropSmartCleanup)
        let openRouter = FakeOpenRouterClient(completion: "cleaned by openrouter")
        let processor = env.processor(openRouter)

        let result = try await processor.process(
            "raw text",
            targetApp: "Slack",
            appContext: "Thread with Alice",
            language: "en",
            outputLanguage: "ru",
            transcriptionMode: "smart"
        )

        XCTAssertEqual(result, "cleaned by openrouter")
        XCTAssertEqual(openRouter.lastAPIKey, "or-key")
        XCTAssertEqual(openRouter.lastEndpoint?.baseURL.absoluteString, "https://openrouter.ai/api/v1")
        XCTAssertEqual(openRouter.lastEndpoint?.requiresAPIKey, true)
        XCTAssertEqual(openRouter.lastEndpoint?.sendsOpenRouterHeaders, true)
        XCTAssertEqual(openRouter.lastModel, "openrouter/auto")
        XCTAssertEqual(openRouter.lastMessages.first?.role, "system")
        XCTAssertTrue(openRouter.lastMessages.first?.content.contains("Главное правило") == true)
        let userMessage = try XCTUnwrap(openRouter.lastMessages.last?.content)
        XCTAssertTrue(userMessage.contains("Active app: Slack"))
        XCTAssertTrue(userMessage.contains("Thread with Alice"))
        XCTAssertTrue(userMessage.contains("<transcript>"))
        XCTAssertTrue(userMessage.contains("raw text"))
        XCTAssertTrue(userMessage.contains("Output language hint: ru"))
        XCTAssertTrue(userMessage.contains("Transcription mode: smart"))
    }

    func test_openrouter_route_without_key_throws_missing_key() async throws {
        let env = makeEnv()
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "openrouter/auto"), for: .dropSmartCleanup)
        let openRouter = FakeOpenRouterClient(completion: "unused")

        do {
            _ = try await env.processor(openRouter).process("raw", targetApp: nil)
            XCTFail("Expected missing key")
        } catch let error as OpenRouterLLMError {
            XCTAssertEqual(error, .missingKey)
        }
        XCTAssertNil(openRouter.lastEndpoint)
    }

    func testServerRouteProcessesDirectlyWithoutRequiredKey() async throws {
        let env = makeEnv()
        let server = env.routing.addServer(name: "Local", baseURL: "http://localhost:8000/v1")
        env.routing.setRoute(FeatureRoute(account: .server(server.id), model: "llama/local"), for: .dropSmartCleanup)
        let openRouter = FakeOpenRouterClient(completion: "cleaned by custom llm")

        let result = try await env.processor(openRouter).process("raw text", targetApp: "Notes")

        XCTAssertEqual(result, "cleaned by custom llm")
        XCTAssertEqual(openRouter.lastAPIKey, nil)
        XCTAssertEqual(openRouter.lastEndpoint?.baseURL.absoluteString, "http://localhost:8000/v1")
        XCTAssertEqual(openRouter.lastEndpoint?.requiresAPIKey, false)
        XCTAssertEqual(openRouter.lastEndpoint?.sendsOpenRouterHeaders, false)
        XCTAssertEqual(openRouter.lastModel, "llama/local")
    }

    func testServerWithoutBaseURLDoesNotFallbackToBackend() async throws {
        let env = makeEnv()
        let server = env.routing.addServer(name: "Local", baseURL: "")
        env.routing.setRoute(FeatureRoute(account: .server(server.id), model: "llama/local"), for: .dropSmartCleanup)
        let openRouter = FakeOpenRouterClient(completion: "unused")

        do {
            _ = try await env.processor(openRouter).process("raw", targetApp: nil)
            XCTFail("Expected missing base URL")
        } catch let error as OpenRouterLLMError {
            XCTAssertEqual(error, .missingBaseURL)
        }
        XCTAssertNil(openRouter.lastEndpoint)
    }

    func test_cleanup_without_route_throws_not_configured() async throws {
        let env = makeEnv()
        // Another feature's route and a stored OpenRouter key do not choose
        // where cleanup goes.
        try env.keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "notes"), for: .meetingNotes)
        let openRouter = FakeOpenRouterClient(completion: "unused")

        do {
            _ = try await env.processor(openRouter).process("raw", targetApp: nil)
            XCTFail("Expected notConfigured")
        } catch let error as OpenRouterLLMError {
            XCTAssertEqual(error, .notConfigured)
        }
        XCTAssertNil(openRouter.lastEndpoint)
    }

    func test_cleanup_uses_only_the_cleanup_route() async throws {
        let env = makeEnv()
        try env.keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        let server = env.routing.addServer(name: "Local", baseURL: "http://llm.local:8080/v1")
        env.routing.setRoute(FeatureRoute(account: .server(server.id), model: "qwen"), for: .dropSmartCleanup)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "notes-model"), for: .meetingNotes)

        StubURLProtocol.reset()
        addTeardownBlock { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": "cleaned"]]]]
            return (200, [:], try JSONSerialization.data(withJSONObject: body))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }

        let result = try await env.processor(OpenRouterLLMClient(session: session, profile: .dictation))
            .process("raw", targetApp: nil)

        XCTAssertEqual(result, "cleaned")
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://llm.local:8080/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(StubURLProtocol.capturedBodies.first)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "qwen")
    }
}

private final class FakeOpenRouterClient: OpenRouterLLMClienting {
    let completion: String
    var models: [OpenRouterModelOption]
    private(set) var lastEndpoint: OpenAICompatibleLLMEndpoint?
    var lastAPIKey: String? { lastEndpoint?.apiKey }
    private(set) var lastModel: String?
    private(set) var lastMessages: [OpenRouterChatMessage] = []

    init(
        completion: String,
        models: [OpenRouterModelOption] = [.init(id: "openrouter/auto", name: "Auto Router")]
    ) {
        self.completion = completion
        self.models = models
    }

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] {
        models
    }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        lastEndpoint = endpoint
        lastModel = model
        lastMessages = messages
        return completion
    }
}
