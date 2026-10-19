import XCTest
@testable import Sidekey

/// The real-time session factory opens each feature on that feature's own
/// route. Routes live in an isolated `UserDefaults` suite and keys in an
/// in-memory Keychain, so nothing reaches the user's settings or Keychain.
@MainActor
final class TranscriptionSessionFactoryTests: XCTestCase {
    private struct Env {
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        let adapterRoutes: Box
        let factory: TranscriptionSessionFactory
    }

    /// What `makeAdapter` was asked to build.
    private final class Box {
        var routes: [ResolvedRoute] = []
    }

    private func makeEnv() -> Env {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let routing = AIRoutingStore(defaults: defaults)
        let tokens = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: tokens) })
        let seen = Box()
        let vocab = VocabularyCache(defaults: UserDefaults(suiteName: "vocab.\(UUID().uuidString)")!)
        let factory = TranscriptionSessionFactory(
            resolver: FeatureRouteResolver(routing: routing, keys: keys),
            vocab: vocab,
            makeAdapter: { route in
                seen.routes.append(route)
                return try RealtimeAdapterFactory.make(route)
            }
        )
        return Env(routing: routing, keys: keys, adapterRoutes: seen, factory: factory)
    }

    private func use(_ account: ProviderAccount, _ model: String, for feature: AIFeature,
                     key: String?, in env: Env) throws {
        env.routing.setRoute(FeatureRoute(account: account, model: model), for: feature)
        if let key {
            let name = try XCTUnwrap(account.keychainAccount(in: env.routing))
            try env.keys.save(key, account: name)
        }
    }

    private func assertMakeThrows(
        _ expected: FeatureRouteError, _ env: Env, feature: AIFeature, language: String?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try env.factory.make(feature: feature, language: language), file: file, line: line) {
            XCTAssertEqual($0 as? FeatureRouteError, expected, file: file, line: line)
        }
        XCTAssertTrue(env.adapterRoutes.routes.isEmpty, "no adapter may be built", file: file, line: line)
    }

    func test_each_hosted_provider_builds_a_direct_session() throws {
        for (account, model) in [(ProviderAccount.deepgram, "nova-3"), (.soniox, "stt-rt-v4"),
                                 (.elevenLabs, "scribe_v2_realtime")] {
            let env = makeEnv()
            try use(account, model, for: .dropFast, key: "key-\(account.storageID)", in: env)
            let session = try env.factory.make(feature: .dropFast, language: "en")
            XCTAssertTrue(session is DirectProviderStreamingSession, "\(account)")
        }
    }

    func test_each_realtime_feature_uses_its_own_route() throws {
        let env = makeEnv()
        try use(.soniox, "stt-rt-v4", for: .dropFast, key: "sx-key", in: env)
        try use(.deepgram, "nova-3", for: .agentVoice, key: "dg-key", in: env)

        _ = try env.factory.make(feature: .dropFast, language: "en")
        _ = try env.factory.make(feature: .agentVoice, language: "en")

        XCTAssertEqual(env.adapterRoutes.routes.count, 2)
        let fast = env.adapterRoutes.routes[0]
        XCTAssertEqual(fast.feature, .dropFast)
        XCTAssertEqual(fast.account, .soniox)
        XCTAssertEqual(fast.model, "stt-rt-v4")
        XCTAssertEqual(fast.apiKey, "sx-key")
        let voice = env.adapterRoutes.routes[1]
        XCTAssertEqual(voice.feature, .agentVoice)
        XCTAssertEqual(voice.account, .deepgram)
        XCTAssertEqual(voice.model, "nova-3")
        XCTAssertEqual(voice.apiKey, "dg-key")
    }

    func test_unset_feature_throws_not_set_for_that_feature() throws {
        let env = makeEnv()
        try use(.soniox, "stt-rt-v4", for: .dropFast, key: "sx-key", in: env)
        assertMakeThrows(.notSet(.voiceSearch), env, feature: .voiceSearch, language: "en")
    }

    func test_missing_key_is_reported_for_the_feature_and_nothing_else_is_tried() throws {
        let env = makeEnv()
        try use(.soniox, "stt-rt-v4", for: .dropFast, key: nil, in: env)
        try use(.deepgram, "nova-3", for: .agentVoice, key: "dg-key", in: env)
        assertMakeThrows(.missingKey(.dropFast), env, feature: .dropFast, language: "en")
    }

    func test_server_without_base_url_throws_before_any_adapter() throws {
        let env = makeEnv()
        let server = env.routing.addServer(name: "Mine", baseURL: "")
        env.routing.setRoute(FeatureRoute(account: .server(server.id), model: "m"), for: .dropFast)
        assertMakeThrows(.missingBaseURL(.dropFast), env, feature: .dropFast, language: "en")
    }

    func test_server_with_an_unusable_base_url_throws_invalid_base_url() throws {
        let env = makeEnv()
        let server = env.routing.addServer(name: "Mine", baseURL: "http://my host:8000")
        env.routing.setRoute(FeatureRoute(account: .server(server.id), model: "m"), for: .dropFast)
        XCTAssertThrowsError(try env.factory.make(feature: .dropFast, language: "en")) {
            XCTAssertEqual($0 as? FeatureRouteError, .invalidBaseURL(.dropFast))
        }
    }

    // MARK: - Deepgram language policy (PR #35), now per feature

    func test_deepgram_language_problem_is_reported_before_the_key() throws {
        let env = makeEnv()
        // No key is stored for Deepgram: the language problem still wins.
        try use(.deepgram, "nova-3", for: .dropFast, key: nil, in: env)
        assertMakeThrows(.invalidLanguageConfiguration(.dropFast, .unsupportedLanguage),
                         env, feature: .dropFast, language: "cy")

        try use(.deepgram, "custom-model", for: .dropFast, key: nil, in: env)
        assertMakeThrows(.invalidLanguageConfiguration(.dropFast, .automaticLanguageUnavailable),
                         env, feature: .dropFast, language: nil)
    }

    func test_deepgram_invalid_language_leaves_the_saved_route_alone() throws {
        let env = makeEnv()
        try use(.deepgram, "nova-3", for: .dropSmart, key: "dg-key", in: env)
        assertMakeThrows(.invalidLanguageConfiguration(.dropSmart, .unsupportedLanguage),
                         env, feature: .dropSmart, language: "cy")
        XCTAssertEqual(env.routing.route(for: .dropSmart), FeatureRoute(account: .deepgram, model: "nova-3"))
    }

    func test_deepgram_unknown_model_with_an_explicit_language_is_preserved() throws {
        let env = makeEnv()
        try use(.deepgram, "custom-model", for: .dropFast, key: "dg-key", in: env)
        XCTAssertThrowsError(try env.factory.make(feature: .dropFast, language: nil)) {
            XCTAssertEqual($0 as? FeatureRouteError, .invalidLanguageConfiguration(.dropFast, .automaticLanguageUnavailable))
        }
        XCTAssertTrue(try env.factory.make(feature: .dropFast, language: "ru") is DirectProviderStreamingSession)
        XCTAssertEqual(env.adapterRoutes.routes.map(\.model), ["custom-model"])
        XCTAssertEqual(env.routing.route(for: .dropFast)?.model, "custom-model")
    }

    func test_language_policy_does_not_apply_to_other_providers() throws {
        let env = makeEnv()
        try use(.soniox, "stt-rt-v4", for: .dropFast, key: "sx-key", in: env)
        XCTAssertTrue(try env.factory.make(feature: .dropFast, language: "cy") is DirectProviderStreamingSession)
    }

    // MARK: - Resilient scoping in the factory (source inspection)
    //
    // CONTRACT: the factory passes `resilient: resilient` to
    // `DirectProviderStreamingSession`, so the Drop flag threads through and a
    // degraded take keeps its PCM for batch recovery.

    func testFactoryPassesResilientToDirectProviderSession() throws {
        let source = try factorySource()
        XCTAssertTrue(
            source.contains("resilient: resilient"),
            "DirectProviderStreamingSession init must pass `resilient: resilient` so the Drop flag threads through."
        )
    }

    private func factorySource() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let factoryURL = candidate.deletingLastPathComponent()
                    .appendingPathComponent("Sources")
                    .appendingPathComponent("Sidekey")
                    .appendingPathComponent("Streaming")
                    .appendingPathComponent("BYOK")
                    .appendingPathComponent("TranscriptionSessionFactory.swift")
                return try String(contentsOf: factoryURL, encoding: .utf8)
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "TranscriptionSessionFactoryTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not locate Package.swift"])
    }
}
