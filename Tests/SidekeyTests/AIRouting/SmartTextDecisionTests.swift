import XCTest
@testable import Sidekey

@MainActor
final class SmartTextDecisionTests: XCTestCase {
    private struct Env {
        let defaults: UserDefaults
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
    }

    private func environment() -> Env {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let box = InMemoryTokenStore.Box()
        return Env(defaults: defaults, routing: AIRoutingStore(defaults: defaults),
                   keys: ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) }))
    }

    private func route(_ account: ProviderAccount = .openRouter) -> ResolvedRoute {
        ResolvedRoute(feature: .dropSmartDecision, account: account,
                      model: account == .openRouter ? ModelRegistry.smartDecisionModel : ModelRegistry.openAIDecisionModel,
                      apiKey: "synthetic-key", server: nil)
    }

    func test_jev_request_uses_decision_endpoint_and_noul_not_chat() throws {
        let request = try TextDecisionClient.request(route: route(), input: "synthetic transcript")
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/alpha/decisions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "typesafe/jev-1.14")
        XCTAssertEqual(body["state"] as? String, "synthetic transcript")
        XCTAssertNil(body["messages"])
        let questions = try XCTUnwrap(body["questions"] as? [String: [String: String]])
        XCTAssertEqual(questions["needs_cleanup"]?["type"], "noul")
    }

    func test_openai_request_uses_decisions_and_predicate() throws {
        let request = try TextDecisionClient.request(route: route(.openAI), input: "synthetic transcript")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/decisions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(body["input"] as? String, "synthetic transcript")
        let questions = try XCTUnwrap(body["questions"] as? [[String: String]])
        XCTAssertEqual(questions.first?["type"], "predicate")
        XCTAssertEqual(questions.first?["name"], "needs_cleanup")
    }

    func test_typed_responses_and_refusals_never_become_generated_text() throws {
        func parse(_ json: String, _ account: ProviderAccount) throws -> Double? {
            try TextDecisionClient.probability(from: Data(json.utf8), account: account)
        }
        XCTAssertEqual(try parse(#"{"answers":{"needs_cleanup":{"type":"noul","noul":0.02}}}"#, .openRouter), 0.02)
        XCTAssertEqual(try parse(#"{"answers":[{"name":"needs_cleanup","type":"predicate","probability":0.7}]}"#, .openAI), 0.7)
        for json in [
            #"{"answers":{"needs_cleanup":{"type":"refusal"}}}"#,
            #"{"answers":{"needs_cleanup":{"type":"noul","noul":-1}}}"#,
            #"{"answers":{"needs_cleanup":{"type":"noul","noul":1.1}}}"#,
            #"{"answers":{"other":{"type":"noul","noul":0}}}"#,
        ] { XCTAssertNil(try parse(json, .openRouter)) }
        XCTAssertNil(try parse(#"{"answers":[{"name":"needs_cleanup","type":"refusal"}]}"#, .openAI))
        XCTAssertNil(try parse(#"{"answers":[{"name":"other","type":"predicate","probability":0}]}"#, .openAI))
        XCTAssertNil(try parse(#"{"answers":[{"name":"needs_cleanup","type":"predicate","probability":0},{"name":"needs_cleanup","type":"predicate","probability":0}]}"#, .openAI))
        XCTAssertThrowsError(try parse(#"{"choices":[{"message":{"content":"Fast"}}]}"#, .openRouter))
    }

    private final class Client: TextDecisionClienting {
        var probability: Double?
        var calls: [ResolvedRoute] = []
        var input: String?
        init(_ probability: Double?) { self.probability = probability }
        func cleanupProbability(route: ResolvedRoute, input: String) async throws -> Double? {
            calls.append(route); self.input = input; return probability
        }
    }

    func test_only_confident_clean_verdict_skips_cleanup_and_uses_own_route() async throws {
        let env = environment()
        try env.keys.save("decision-key", account: ProviderAccount.openAI.keychainAccount(in: env.routing)!)
        env.routing.setRoute(FeatureRoute(account: .openAI, model: ModelRegistry.openAIDecisionModel), for: .dropSmartDecision)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "cleanup-model"), for: .dropSmartCleanup)
        let client = Client(0.01)
        let decision = SmartTextDecision(resolver: FeatureRouteResolver(routing: env.routing, keys: env.keys), client: client)
        for (p, expected) in [(0.0, true), (0.05, true), (0.051, false), (0.5, false), (1.0, false), (-1.0, false), (Double.nan, false)] {
            client.probability = p
            let result = try await decision.canUseFastPath("Hello.", targetApp: "Notes", appContext: "reference", language: "en")
            XCTAssertEqual(result, expected)
        }
        XCTAssertTrue(client.calls.allSatisfy { $0.account == .openAI && $0.apiKey == "decision-key" })
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(client.input).utf8)) as? [String: String])
        XCTAssertEqual(state["transcript"], "Hello.")
        XCTAssertTrue(state["context"]?.contains("reference") == true)
        client.probability = nil
        let noAnswer = try await decision.canUseFastPath("Hello.", targetApp: nil, appContext: nil, language: nil)
        XCTAssertFalse(noAnswer)
    }

    func test_long_transcript_keeps_smart_without_truncating_or_sending() async throws {
        let env = environment(), client = Client(0)
        let decision = SmartTextDecision(resolver: FeatureRouteResolver(routing: env.routing, keys: env.keys), client: client)
        let result = try await decision.canUseFastPath(String(repeating: "x", count: 16_001), targetApp: nil, appContext: nil, language: nil)
        XCTAssertFalse(result)
        XCTAssertTrue(client.calls.isEmpty)
    }

    func test_default_jev_added_once_without_replacing_existing_routes_or_restoring_removed_key() throws {
        let env = environment()
        let cleanup = FeatureRoute(account: .anthropic, model: "existing-model")
        env.routing.setRoute(cleanup, for: .dropSmartCleanup)
        env.routing.initializeSmartDecisionIfNeeded()
        XCTAssertEqual(env.routing.route(for: .dropSmartDecision), FeatureRoute(account: .openRouter, model: "typesafe/jev-1.14"))
        XCTAssertEqual(env.routing.route(for: .dropSmartCleanup), cleanup)
        env.routing.clearRoutes(using: .openRouter)
        let restored = AIRoutingStore(defaults: env.defaults)
        restored.initializeSmartDecisionIfNeeded()
        XCTAssertNil(restored.route(for: .dropSmartDecision))
        XCTAssertEqual(restored.route(for: .dropSmartCleanup), cleanup)
    }

    func test_existing_openai_decision_choice_round_trips_and_survives_migration() {
        let env = environment()
        let selected = FeatureRoute(account: .openAI, model: ModelRegistry.openAIDecisionModel)
        env.routing.setRoute(selected, for: .dropSmartDecision)
        env.routing.initializeSmartDecisionIfNeeded()
        XCTAssertEqual(AIRoutingStore(defaults: env.defaults).route(for: .dropSmartDecision), selected)
    }

    private final class Judge: SmartTextDeciding {
        var calls = 0
        var cancels = false
        var result: Result<Bool, Error> = .success(true)
        func canUseFastPath(_ text: String, targetApp: String?, appContext: String?, language: String?) async throws -> Bool {
            if cancels { withUnsafeCurrentTask { $0?.cancel() } }
            calls += 1; return try result.get()
        }
    }
    private final class Editor: OpenRouterLLMClienting {
        var calls = 0
        var fail = false
        func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] { [] }
        func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
            calls += 1
            if fail { throw OpenRouterLLMError.emptyContent }
            return "Edited."
        }
    }

    func test_processor_skips_editor_only_on_clean_verdict_and_never_skips_translation() async throws {
        let env = environment(), judge = Judge(), editor = Editor()
        try env.keys.save("cleanup-key", account: OpenRouterLLMKeyStore.account)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "cleanup-model"), for: .dropSmartCleanup)
        let processor = PostProcessor(llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: env.routing, keys: env.keys),
                                      openRouterClient: editor, decision: judge)
        let verbatim = try await processor.process("Hello.", targetApp: nil)
        XCTAssertEqual(verbatim, "Hello.")
        XCTAssertEqual(editor.calls, 0)
        let translated = try await processor.process("Hello.", targetApp: nil, outputLanguage: "ru")
        XCTAssertEqual(translated, "Edited.")
        XCTAssertEqual(judge.calls, 1)
        judge.result = .success(false)
        let edited = try await processor.process("uh hello", targetApp: nil)
        XCTAssertEqual(edited, "Edited.")
        judge.result = .failure(URLError(.timedOut))
        let afterTimeout = try await processor.process("uh hello", targetApp: nil)
        XCTAssertEqual(afterTimeout, "Edited.")
        editor.fail = true
        do {
            _ = try await processor.process("uh hello", targetApp: nil)
            XCTFail("Smart editor errors must reach Retry")
        } catch { XCTAssertEqual(error as? OpenRouterLLMError, .emptyContent) }
    }

    func test_catalog_separates_decisions_from_chat_and_keeps_openai_capabilities() throws {
        let models = try ModelCatalogFetcher.parseOpenRouter(Data(#"{"data":[{"id":"typesafe/jev-1.14","architecture":{"output_modalities":["text"]}},{"id":"example/decision","architecture":{"output_modalities":["decision"]}},{"id":"example/chat","architecture":{"output_modalities":["text"]}}]}"#.utf8))
        XCTAssertEqual(models.first { $0.id == "typesafe/jev-1.14" }?.uses, [.decision])
        XCTAssertEqual(models.first { $0.id == "example/decision" }?.uses, [.decision])
        XCTAssertEqual(models.first { $0.id == "example/chat" }?.uses, [.chat])
        let openAI = try ModelCatalogFetcher.parseOpenAI(Data(#"{"data":[{"id":"gpt-6-luna"},{"id":"gpt-4o"}]}"#.utf8))
        XCTAssertTrue(openAI.first { $0.id == "gpt-6-luna" }?.uses?.contains(.decision) == true)
        XCTAssertFalse(openAI.first { $0.id == "gpt-4o" }?.uses?.contains(.decision) == true)
        XCTAssertNotNil(ModelRegistry.knownUnsupportedReason("typesafe/jev-1.14", kind: .openRouter, use: .chat))
        XCTAssertNotNil(ModelRegistry.knownUnsupportedReason("gpt-4o", kind: .openAI, use: .decision))
    }

    func testRecognizedDestinationDoesNotForceExtraEditorCallForCleanText() async throws {
        let env = environment(), judge = Judge(), editor = Editor()
        try env.keys.save("cleanup-key", account: OpenRouterLLMKeyStore.account)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "cleanup-model"), for: .dropSmartCleanup)
        let processor = PostProcessor(llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: env.routing, keys: env.keys), openRouterClient: editor, decision: judge)
        let text = "Проверь a*b*c и __literal__."
        let result = try await processor.processOutput(text, targetApp: "Telegram", formatting: .telegram)
        XCTAssertEqual(result.text, text)
        XCTAssertFalse(result.usedEditor)
        XCTAssertEqual(result.deliveryProfile(.telegram), .plain)
        XCTAssertEqual(editor.calls, 0)
        XCTAssertEqual(judge.calls, 1)
        judge.result = .success(false)
        let edited = try await processor.processOutput("uh hello", targetApp: "Telegram", formatting: .telegram)
        XCTAssertTrue(edited.usedEditor)
        XCTAssertEqual(edited.deliveryProfile(.telegram), .telegram)
        XCTAssertEqual(editor.calls, 1)
    }

    func test_cancelling_decision_stops_both_raw_delivery_and_editor() async throws {
        let env = environment(), judge = Judge(), editor = Editor()
        judge.cancels = true
        try env.keys.save("cleanup-key", account: OpenRouterLLMKeyStore.account)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "cleanup-model"), for: .dropSmartCleanup)
        let processor = PostProcessor(llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: env.routing, keys: env.keys),
                                      openRouterClient: editor, decision: judge)
        let task = Task { try await processor.process("Hello.", targetApp: nil) }
        do {
            _ = try await task.value
            XCTFail("Cancelled take must not produce output")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(editor.calls, 0)
    }

    func test_missing_cleanup_configuration_cannot_be_bypassed_by_clean_decision() async throws {
        let env = environment(), judge = Judge(), editor = Editor()
        let processor = PostProcessor(llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: env.routing, keys: env.keys),
                                      openRouterClient: editor, decision: judge)
        do {
            _ = try await processor.process("Hello.", targetApp: nil)
            XCTFail("Smart configuration still required")
        } catch { XCTAssertEqual(error as? OpenRouterLLMError, .notConfigured) }
        XCTAssertEqual(judge.calls, 0)
    }

    func test_transport_records_runtime_cost_but_probe_excludes_it() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            (200, [:], Data(#"{"model":"typesafe/jev-1.14-20261014","answers":{"needs_cleanup":{"type":"noul","noul":0.03}},"usage":{"cost":0.00001}}"#.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var events: [AIUsageEvent] = []
        let client = TextDecisionClient(session: session, usageSink: { events.append($0) })
        let result = try await client.cleanupProbability(route: route(), input: "synthetic")
        XCTAssertEqual(result, 0.03)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].context.feature, .dropSmartDecision)
        XCTAssertEqual(events[0].amount, 0.00001)
        XCTAssertEqual(events[0].basis, .reported)
        XCTAssertEqual(events[0].context.model, "typesafe/jev-1.14-20261014")
        let probe = await ModelProbe(session: session).probe(route(), use: .decision, catalog: nil)
        XCTAssertEqual(probe, .passed)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(StubURLProtocol.capturedRequests.allSatisfy { $0.url?.path == "/api/alpha/decisions" })
    }

    private final class Unresponsive: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }

    func test_unresponsive_endpoint_has_whole_request_deadline() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Unresponsive.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = TextDecisionClient(session: session, timeout: 0.05, usageSink: { _ in })
        let started = ContinuousClock.now
        do {
            _ = try await client.cleanupProbability(route: route(), input: "synthetic")
            XCTFail("Expected deadline")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }
}
