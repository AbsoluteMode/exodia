import XCTest
@testable import Sidekey

/// Turning a feature's stored route into something the runtime can call: the
/// route's model plus the key of the route's own provider account, or the
/// reason it cannot run. Each test gets its own routes (an isolated
/// `UserDefaults` suite) and its own in-memory Keychain, so nothing reaches
/// `UserDefaults.standard` or the login Keychain.
@MainActor
final class FeatureRouteResolverTests: XCTestCase {

    private struct Env {
        let routing: AIRoutingStore
        let box: InMemoryTokenStore.Box
        let keys: ProviderKeyStore
        let resolver: FeatureRouteResolver
    }

    private func makeEnv() -> Env {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        return Env(
            routing: routing, box: box, keys: keys,
            resolver: FeatureRouteResolver(routing: routing, keys: keys)
        )
    }

    private func saveKey(_ key: String, for account: ProviderAccount, in env: Env) throws {
        let name = try XCTUnwrap(account.keychainAccount(in: env.routing), "no Keychain account for \(account)")
        try env.keys.save(key, account: name)
    }

    private func assertThrows(
        _ expected: FeatureRouteError,
        file: StaticString = #filePath, line: UInt = #line,
        _ resolve: () throws -> ResolvedRoute
    ) {
        XCTAssertThrowsError(try resolve(), file: file, line: line) { error in
            XCTAssertEqual(error as? FeatureRouteError, expected, file: file, line: line)
        }
    }

    /// Shaped like the consumers later tasks add: the resolver is a default
    /// argument of a main-actor init and of a main-actor static function. Tests
    /// pass their own resolver, so the defaults are compiled but never run.
    @MainActor
    private struct ResolverConsumer {
        private let resolver: FeatureRouteResolver

        init(resolver: FeatureRouteResolver = FeatureRouteResolver()) {
            self.resolver = resolver
        }

        func route(for feature: AIFeature) throws -> ResolvedRoute {
            try resolver.resolve(feature)
        }

        @MainActor
        static func route(for feature: AIFeature, resolver: FeatureRouteResolver = FeatureRouteResolver()) throws -> ResolvedRoute {
            try resolver.resolve(feature)
        }
    }

    // MARK: - Provider accounts

    func test_unset_feature_is_not_set() {
        let env = makeEnv()

        assertThrows(.notSet(.dropSmart)) { try env.resolver.resolve(.dropSmart) }
        // The same answer through consumers that take the resolver as a default argument.
        assertThrows(.notSet(.dropSmart)) { try ResolverConsumer(resolver: env.resolver).route(for: .dropSmart) }
        assertThrows(.notSet(.dropSmart)) { try ResolverConsumer.route(for: .dropSmart, resolver: env.resolver) }
    }

    func test_route_resolves_with_the_key_of_its_own_account() throws {
        let env = makeEnv()
        let cases: [(AIFeature, ProviderAccount, String)] = [
            (.dropFast, .soniox, "stt-rt-v4"),
            (.dropSmart, .deepgram, "nova-3"),
            (.voiceSearch, .elevenLabs, "scribe_v2_realtime"),
            (.meetingNotes, .openRouter, "google/gemini-2.5-flash"),
        ]
        for (feature, account, model) in cases {
            try saveKey("key-\(account.storageID)", for: account, in: env)
            env.routing.setRoute(FeatureRoute(account: account, model: model), for: feature)
        }

        for (feature, account, model) in cases {
            XCTAssertEqual(
                try env.resolver.resolve(feature),
                ResolvedRoute(feature: feature, account: account, model: model, apiKey: "key-\(account.storageID)", server: nil)
            )
        }
    }

    func test_missing_key_never_falls_back_to_another_provider() throws {
        let env = makeEnv()
        env.routing.setRoute(FeatureRoute(account: .deepgram, model: "nova-3"), for: .dropFast)
        try saveKey("soniox-key", for: .soniox, in: env)
        try saveKey("eleven-key", for: .elevenLabs, in: env)
        try saveKey("router-key", for: .openRouter, in: env)

        assertThrows(.missingKey(.dropFast)) { try env.resolver.resolve(.dropFast) }

        // Only Deepgram's own key makes the feature resolve, and then to Deepgram.
        try saveKey("deepgram-key", for: .deepgram, in: env)
        let resolved = try env.resolver.resolve(.dropFast)
        XCTAssertEqual(resolved.account, .deepgram)
        XCTAssertEqual(resolved.apiKey, "deepgram-key")
    }

    func test_blank_stored_key_is_a_missing_key() throws {
        let env = makeEnv()
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v4"), for: .dropFast)
        let name = try XCTUnwrap(ProviderAccount.soniox.keychainAccount(in: env.routing))
        // Written straight into the slot, the way an older build could have
        // left it: present, but only whitespace.
        try InMemoryTokenStore(account: name, box: env.box).save(" \n")

        assertThrows(.missingKey(.dropFast)) { try env.resolver.resolve(.dropFast) }
    }

    // MARK: - Servers

    func test_server_without_key_resolves_with_nil_key() throws {
        let env = makeEnv()
        let server = env.routing.addServer(name: "Home GPU", baseURL: "https://gpu.local:8000")
        env.routing.setRoute(FeatureRoute(account: .server(server.id), model: "whisper-large-v3"), for: .dropFast)

        let resolved = try env.resolver.resolve(.dropFast)

        XCTAssertEqual(
            resolved,
            ResolvedRoute(feature: .dropFast, account: .server(server.id), model: "whisper-large-v3", apiKey: nil, server: server)
        )
    }

    func test_each_server_resolves_with_its_own_key() throws {
        let env = makeEnv()
        let migrated = ServerEndpoint(
            id: UUID(), name: "Home GPU", baseURL: "https://gpu.local:8000",
            keyAccount: "byok.selfHosted.api_key"
        )
        env.routing.completeMigration(routes: [:], servers: [migrated])
        let added = env.routing.addServer(name: "Office", baseURL: "https://llm.office.example")
        env.routing.setRoute(FeatureRoute(account: .server(migrated.id), model: "whisper-large-v3"), for: .meetings)
        env.routing.setRoute(FeatureRoute(account: .server(added.id), model: "whisper-large-v3"), for: .dropFast)
        try saveKey("legacy-key", for: .server(migrated.id), in: env)
        try saveKey("office-key", for: .server(added.id), in: env)

        XCTAssertEqual(try env.resolver.resolve(.meetings).apiKey, "legacy-key")
        XCTAssertEqual(try env.resolver.resolve(.dropFast).apiKey, "office-key")
        XCTAssertEqual(try env.resolver.resolve(.dropFast).server, added)
    }

    func test_deleted_server_is_not_set() throws {
        let env = makeEnv()
        let server = env.routing.addServer(name: "Home GPU", baseURL: "https://gpu.local:8000")
        let route = FeatureRoute(account: .server(server.id), model: "whisper-large-v3")
        env.routing.setRoute(route, for: .meetings)
        XCTAssertNoThrow(try env.resolver.resolve(.meetings), "resolves while the server exists")

        env.routing.removeServer(server.id)

        assertThrows(.notSet(.meetings)) { try env.resolver.resolve(.meetings) }
        // The store has already un-set the feature; a candidate route that still
        // names the removed server shows the resolver itself refuses it too.
        assertThrows(.notSet(.meetings)) { try env.resolver.resolve(route, for: .meetings) }
    }

    func test_server_with_blank_base_url_is_missing_base_url() {
        let env = makeEnv()
        for baseURL in ["", "  \n"] {
            let server = env.routing.addServer(name: "Blank", baseURL: baseURL)
            env.routing.setRoute(FeatureRoute(account: .server(server.id), model: "whisper-large-v3"), for: .dropFast)

            assertThrows(.missingBaseURL(.dropFast)) { try env.resolver.resolve(.dropFast) }
        }
    }

    // MARK: - Model

    func test_blank_model_is_not_set() throws {
        let env = makeEnv()
        try saveKey("sk-soniox", for: .soniox, in: env)

        for model in ["", "  \n"] {
            env.routing.setRoute(FeatureRoute(account: .soniox, model: model), for: .dropFast)

            assertThrows(.notSet(.dropFast)) { try env.resolver.resolve(.dropFast) }
        }
    }

    func test_resolved_model_is_trimmed() throws {
        let env = makeEnv()
        try saveKey("sk-deepgram", for: .deepgram, in: env)
        env.routing.setRoute(FeatureRoute(account: .deepgram, model: "  nova-3\n"), for: .dropFast)

        XCTAssertEqual(try env.resolver.resolve(.dropFast).model, "nova-3")
    }

    // MARK: - Candidate routes

    /// A model probe resolves a route nobody has picked yet. Same rules, and
    /// the feature's stored route stays exactly as it was.
    func test_candidate_route_follows_the_same_rules_and_leaves_the_stored_route_alone() throws {
        let env = makeEnv()
        let stored = FeatureRoute(account: .soniox, model: "stt-rt-v4")
        env.routing.setRoute(stored, for: .dropFast)
        let candidate = FeatureRoute(account: .deepgram, model: "nova-3")

        assertThrows(.missingKey(.dropFast)) { try env.resolver.resolve(candidate, for: .dropFast) }

        try saveKey("deepgram-key", for: .deepgram, in: env)
        XCTAssertEqual(
            try env.resolver.resolve(candidate, for: .dropFast),
            ResolvedRoute(feature: .dropFast, account: .deepgram, model: "nova-3", apiKey: "deepgram-key", server: nil)
        )
        XCTAssertEqual(env.routing.route(for: .dropFast), stored)
    }

    // MARK: - Errors

    func test_error_knows_its_feature() {
        XCTAssertEqual(FeatureRouteError.notSet(.dropFast).feature, .dropFast)
        XCTAssertEqual(FeatureRouteError.missingKey(.dropSmart).feature, .dropSmart)
        XCTAssertEqual(FeatureRouteError.missingBaseURL(.meetings).feature, .meetings)
        XCTAssertEqual(FeatureRouteError.invalidBaseURL(.agentVoice).feature, .agentVoice)
        XCTAssertEqual(
            FeatureRouteError.invalidLanguageConfiguration(.voiceSearch, .unsupportedLanguage).feature,
            .voiceSearch
        )
    }
}
