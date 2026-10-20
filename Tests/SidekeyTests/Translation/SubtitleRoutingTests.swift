import XCTest
@testable import Sidekey

@MainActor
final class SubtitleRoutingTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private let speech = FeatureRoute(account: .soniox, model: "stt-rt-v5")
    private let shared = FeatureRoute(account: .openRouter, model: "old-translation", provider: "old-provider")

    func testConfiguredSubtitlesKeepTheExactPreviousLLMOnce() {
        let defaults = makeDefaults()
        let routing = AIRoutingStore(defaults: defaults)
        routing.completeMigration(routes: [.subtitlesAudio: speech, .translation: shared], servers: [])
        let snapshot = routing.state.migratedRoutes

        routing.separateSubtitleTranslationIfNeeded()

        XCTAssertEqual(routing.route(for: .subtitlesTranslation), shared)
        XCTAssertEqual(routing.route(for: .translation), shared)
        XCTAssertEqual(routing.route(for: .subtitlesAudio), speech)
        XCTAssertEqual(routing.state.migratedRoutes, snapshot, "do not grant legacy model verification to the new route")
        XCTAssertEqual(routing.state.migrationVersion, 2)

        routing.setRoute(FeatureRoute(account: .openRouter, model: "new-text"), for: .translation)
        let reloaded = AIRoutingStore(defaults: defaults)
        reloaded.separateSubtitleTranslationIfNeeded()
        XCTAssertEqual(reloaded.route(for: .subtitlesTranslation), shared)
        reloaded.setRoute(nil, for: .subtitlesTranslation)
        let unset = AIRoutingStore(defaults: defaults)
        unset.separateSubtitleTranslationIfNeeded()
        XCTAssertNil(unset.route(for: .subtitlesTranslation), "relaunch must not refill an explicitly unset subtitle LLM")
    }

    func testAnExistingIndependentRouteIsNeverOverwritten() {
        let routing = AIRoutingStore(defaults: makeDefaults())
        let separate = FeatureRoute(account: .openRouter, model: "subtitle-only", provider: "subtitle-provider")
        routing.completeMigration(routes: [.subtitlesAudio: speech, .translation: shared, .subtitlesTranslation: separate], servers: [])
        routing.separateSubtitleTranslationIfNeeded()
        XCTAssertEqual(routing.route(for: .subtitlesTranslation), separate)
    }

    func testUnconfiguredSubtitlesNeverAcquireTheTextTranslatorsRoute() {
        for routes: [AIFeature: FeatureRoute] in [[:], [.translation: shared], [.subtitlesAudio: speech]] {
            let routing = AIRoutingStore(defaults: makeDefaults())
            routing.completeMigration(routes: routes, servers: [])
            routing.separateSubtitleTranslationIfNeeded()
            routing.setRoute(shared, for: .translation)
            routing.setRoute(speech, for: .subtitlesAudio)
            routing.separateSubtitleTranslationIfNeeded()
            XCTAssertNil(routing.route(for: .subtitlesTranslation))
        }
    }

    func testCustomServerAndProviderRemovalStayScopedAfterMigration() {
        let routing = AIRoutingStore(defaults: makeDefaults())
        let server = routing.addServer(name: "Fixture", baseURL: "https://fixture.invalid/v1")
        let custom = FeatureRoute(account: .server(server.id), model: "custom-subtitles")
        routing.completeMigration(routes: [.subtitlesAudio: speech, .translation: custom], servers: [server])
        routing.separateSubtitleTranslationIfNeeded()
        XCTAssertEqual(routing.route(for: .subtitlesTranslation), custom)
        routing.setRoute(shared, for: .translation)
        routing.removeServer(server.id)
        XCTAssertNil(routing.route(for: .subtitlesTranslation))
        XCTAssertEqual(routing.route(for: .translation), shared)
    }

    func testPartiallyUnreadableDocumentsAreNotRewrittenByTheSplit() throws {
        let defaults = makeDefaults()
        let raw = Data(#"{"routes":{"translation":{"account":"openRouter","model":"old"},"future":{"account":"unknown","model":"future"}},"migratedRoutes":{},"servers":[],"migrationVersion":1}"#.utf8)
        defaults.set(raw, forKey: AIRoutingStore.defaultsKey)
        AIRoutingStore(defaults: defaults).separateSubtitleTranslationIfNeeded()
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), raw)
    }

    func testTranslationServicesResolveIndependentRoutesWithoutNetworkRequests() async throws {
        let routing = AIRoutingStore(defaults: makeDefaults())
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        try keys.save("fixture-key", account: OpenRouterLLMKeyStore.account)
        routing.setRoute(shared, for: .translation)
        let server = routing.addServer(name: "Subtitle server", baseURL: "https://subtitles.invalid/v1")
        routing.setRoute(FeatureRoute(account: .server(server.id), model: "subtitle-only"), for: .subtitlesTranslation)

        let text = try await TranslationService.live(routing: routing, keys: keys)
        let subtitles = try await TranslationService.live(for: .subtitlesTranslation, routing: routing, keys: keys)
        XCTAssertEqual(text.route.model, shared.model)
        XCTAssertEqual(subtitles.route.model, "subtitle-only")
        XCTAssertEqual(subtitles.route.endpoint.baseURL.absoluteString, server.baseURL)
        XCTAssertNil(subtitles.route.endpoint.apiKey, "a subtitle server must not borrow the text translator's key")

        routing.setRoute(nil, for: .subtitlesTranslation)
        do {
            _ = try await TranslationService.live(for: .subtitlesTranslation, routing: routing, keys: keys)
            XCTFail("text Translation must never be a runtime fallback")
        } catch {
            XCTAssertEqual(error as? OpenRouterLLMError, .notConfigured)
        }
    }

    private func partialState(in defaults: UserDefaults) throws -> Data {
        let state = AIRoutingState(routes: [AIFeature.subtitlesAudio.rawValue: speech,
                                           AIFeature.translation.rawValue: shared],
                                   migratedRoutes: [:], servers: [], migrationVersion: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var routes = try XCTUnwrap(object["routes"] as? [String: Any])
        routes["future"] = ["account": "unknown", "model": "future"]
        object["routes"] = routes
        let raw = try JSONSerialization.data(withJSONObject: object)
        defaults.set(raw, forKey: AIRoutingStore.defaultsKey)
        return raw
    }

    func testExplicitChoiceThenClearInPartialDocumentStaysClearedAfterRelaunch() throws {
        let defaults = makeDefaults()
        let raw = try partialState(in: defaults)
        let routing = AIRoutingStore(defaults: defaults)
        routing.separateSubtitleTranslationIfNeeded()
        routing.setRoute(FeatureRoute(account: .openRouter, model: "subtitle-only"), for: .subtitlesTranslation)
        routing.setRoute(nil, for: .subtitlesTranslation)
        let reloaded = AIRoutingStore(defaults: defaults)
        reloaded.separateSubtitleTranslationIfNeeded()
        XCTAssertNil(reloaded.route(for: .subtitlesTranslation))
        XCTAssertEqual(reloaded.route(for: .translation), shared)
        XCTAssertEqual(reloaded.state.migrationVersion, 2)
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.backupKey), raw)
    }

    func testRemovingSubtitleServerFromPartialDocumentDoesNotReseedAfterRelaunch() throws {
        let defaults = makeDefaults()
        let raw = try partialState(in: defaults)
        let routing = AIRoutingStore(defaults: defaults)
        let server = routing.addServer(name: "Subtitle only", baseURL: "https://subtitles.invalid/v1")
        routing.setRoute(FeatureRoute(account: .server(server.id), model: "subtitle-only"), for: .subtitlesTranslation)
        routing.removeServer(server.id)
        let reloaded = AIRoutingStore(defaults: defaults)
        reloaded.separateSubtitleTranslationIfNeeded()
        XCTAssertNil(reloaded.route(for: .subtitlesTranslation))
        XCTAssertEqual(reloaded.route(for: .translation), shared)
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.backupKey), raw)
    }

    func testFirstPartialEditSplitsBeforeChangingTheTextTranslator() throws {
        let defaults = makeDefaults()
        let raw = try partialState(in: defaults)
        let routing = AIRoutingStore(defaults: defaults)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "new-text"), for: .translation)
        XCTAssertEqual(routing.route(for: .subtitlesTranslation), shared)
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.backupKey), raw)
        routing.clearRoutes(using: .openRouter)
        routing.setRoute(shared, for: .translation)
        let reloaded = AIRoutingStore(defaults: defaults)
        reloaded.separateSubtitleTranslationIfNeeded()
        XCTAssertNil(reloaded.route(for: .subtitlesTranslation))
    }

    func testPartialDocumentNoOpsStayUntouchedButExplicitSubtitleClearIsRetained() throws {
        let defaults = makeDefaults()
        let raw = try partialState(in: defaults)
        let routing = AIRoutingStore(defaults: defaults)
        routing.setRoute(nil, for: .agent)
        routing.setRoute(shared, for: .translation)
        routing.removeServer(UUID())
        routing.clearRoutes(using: .deepgram)
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), raw)
        XCTAssertNil(defaults.data(forKey: AIRoutingStore.backupKey))

        routing.setRoute(nil, for: .subtitlesTranslation)
        let reloaded = AIRoutingStore(defaults: defaults)
        reloaded.separateSubtitleTranslationIfNeeded()
        XCTAssertNil(reloaded.route(for: .subtitlesTranslation))
        XCTAssertEqual(reloaded.state.migrationVersion, 2)
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.backupKey), raw)
    }

    func testSelectingThePreviousSharedRouteInAPartialDocumentIsAnExplicitChoice() throws {
        let defaults = makeDefaults()
        let raw = try partialState(in: defaults)
        let routing = AIRoutingStore(defaults: defaults)
        routing.setRoute(shared, for: .subtitlesTranslation)
        XCTAssertEqual(routing.route(for: .subtitlesTranslation), shared)
        XCTAssertEqual(routing.state.migrationVersion, 2)
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.backupKey), raw)
        XCTAssertEqual(AIRoutingStore(defaults: defaults).route(for: .subtitlesTranslation), shared)
    }

    func testLLMFailuresTargetSubtitleSettingsAndKeepProviderContentPrivate() async {
        for error in [OpenRouterLLMError.notConfigured, .unexpectedStatus(401, "fixture-private-content")] {
            let issue = TranslationIssue.from(error, feature: .subtitlesTranslation)
            XCTAssertEqual(issue.feature, .subtitlesTranslation)
            XCTAssertFalse(issue.message.contains("fixture-private-content"))
        }
    }
}
