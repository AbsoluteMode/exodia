import XCTest
@testable import Sidekey

@MainActor
final class ModelStatusResolverTests: XCTestCase {
    @MainActor private struct Env {
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        let catalogs: ModelCatalogStore
        let checks: ModelCheckStore
        let keyStatuses: KeyStatusStore
        let resolver: ModelStatusResolver

        func addKey(_ account: ProviderAccount) {
            if let name = account.keychainAccount(in: routing) { try? keys.save("key", account: name) }
        }
    }

    private func fresh(_ models: [CatalogModel]) -> CatalogSnapshot {
        CatalogSnapshot(models: models, fetchedAt: Date(), lastRefreshFailed: false, limited: false)
    }

    private func makeEnv(
        snapshots: [ProviderAccount: CatalogSnapshot] = [:],
        keyed: [ProviderAccount] = [],
        adapterVersion: Int = 1
    ) throws -> Env {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        let stored = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.storageID, $0.value) })
        try JSONEncoder().encode(stored).write(to: file)

        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let checks = ModelCheckStore(defaults: defaults)
        let keyStatuses = KeyStatusStore(defaults: defaults)
        let catalogs = ModelCatalogStore(fileURL: file)
        let env = Env(
            routing: routing, keys: keys, catalogs: catalogs, checks: checks, keyStatuses: keyStatuses,
            resolver: ModelStatusResolver(
                routing: routing, keys: keys, catalogs: catalogs, checks: checks, keyStatuses: keyStatuses,
                adapterVersion: { _, _ in adapterVersion }
            )
        )
        for account in keyed { env.addKey(account) }
        return env
    }

    private func sonioxCatalog() -> CatalogSnapshot {
        fresh([
            CatalogModel(id: "stt-rt-v5", uses: [.realtimeSTT]),
            CatalogModel(id: "stt-rt-v4", uses: [.realtimeSTT], aliasOf: "stt-rt-v5"),
            CatalogModel(id: "stt-async-v5", uses: [.asyncSTT]),
        ])
    }

    func test_prod_after_migration_shows_one_switch_for_four_features() throws {
        let env = try makeEnv(snapshots: [.soniox: sonioxCatalog()], keyed: [.soniox])
        let rt = FeatureRoute(account: .soniox, model: "stt-rt-v4")
        env.routing.completeMigration(
            routes: [
                .dropFast: rt, .dropSmart: rt, .agentVoice: rt, .voiceSearch: rt,
                .meetings: FeatureRoute(account: .soniox, model: "stt-async-v5"),
            ],
            servers: []
        )

        XCTAssertEqual(env.resolver.aliasGroups(), [AliasGroupAction(
            account: .soniox, from: "stt-rt-v4", to: "stt-rt-v5",
            features: [.dropFast, .dropSmart, .agentVoice, .voiceSearch]
        )])
        XCTAssertEqual(env.resolver.status(for: .dropFast), .deprecatedAlias(of: "stt-rt-v5"))
        XCTAssertEqual(env.resolver.status(for: .meetings), .ok)
    }

    func test_migrated_model_without_problem_signs_has_no_badge() throws {
        let model = "vendor/legacy-model"
        let env = try makeEnv(
            snapshots: [.openRouter: fresh([CatalogModel(id: model, uses: [.chat])])], keyed: [.openRouter]
        )
        let route = FeatureRoute(account: .openRouter, model: model)
        env.routing.completeMigration(routes: [.dropSmartCleanup: route], servers: [])

        XCTAssertEqual(env.resolver.status(for: .dropSmartCleanup), .ok)
    }

    func test_adapter_version_bump_marks_unregistered_models_not_verified() throws {
        let model = "vendor/legacy-model"
        let snapshot = fresh([
            CatalogModel(id: model, uses: [.chat]),
            CatalogModel(id: "google/gemini-3.8-flash", uses: [.chat]),
        ])
        let route = FeatureRoute(account: .openRouter, model: model)

        let bumped = try makeEnv(snapshots: [.openRouter: snapshot], keyed: [.openRouter], adapterVersion: 2)
        bumped.routing.completeMigration(routes: [.dropSmartCleanup: route], servers: [])
        let key = ModelCheckKey(account: "openRouter", model: model, use: .chat)
        bumped.checks.store(.passed, for: key, adapterVersion: 1, at: Date())
        XCTAssertEqual(bumped.resolver.status(for: .dropSmartCleanup), .notVerified)

        bumped.checks.store(.passed, for: key, adapterVersion: 2, at: Date())
        XCTAssertEqual(bumped.resolver.status(for: .dropSmartCleanup), .ok)

        // A registry model stays checked across a bump.
        bumped.routing.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .meetingNotes)
        XCTAssertEqual(bumped.resolver.status(for: .meetingNotes), .ok)
    }

    func test_removed_only_when_the_catalog_is_authoritative() throws {
        let route = FeatureRoute(account: .openRouter, model: "vendor/gone")
        let other = [CatalogModel(id: "vendor/other", uses: [.chat])]
        let cases: [(CatalogSnapshot, ModelRowStatus)] = [
            (CatalogSnapshot(models: other, fetchedAt: Date(), lastRefreshFailed: true, limited: false), .ok),
            (CatalogSnapshot(models: other, fetchedAt: Date(), lastRefreshFailed: false, limited: true), .ok),
            (fresh(other), .removedByProvider),
        ]
        for (snapshot, expected) in cases {
            let env = try makeEnv(snapshots: [.openRouter: snapshot], keyed: [.openRouter])
            env.routing.completeMigration(routes: [.dropSmartCleanup: route], servers: [])
            XCTAssertEqual(env.resolver.status(for: .dropSmartCleanup), expected)
        }
    }

    func test_deepgram_nova_3_is_not_removed() throws {
        let json = #"{"stt":[{"canonical_name":"nova-3-general","streaming":true,"batch":true}]}"#
        let models = try ModelCatalogFetcher.parseDeepgram(Data(json.utf8))
        let env = try makeEnv(snapshots: [.deepgram: fresh(models)], keyed: [.deepgram])
        env.routing.setRoute(FeatureRoute(account: .deepgram, model: "nova-3"), for: .dropFast)

        XCTAssertEqual(env.resolver.status(for: .dropFast), .ok)
    }

    func test_agent_picker_marks_models_without_tools() throws {
        let env = try makeEnv(
            snapshots: [.openRouter: fresh([
                CatalogModel(id: "x/with-tools", uses: [.chat, .chatWithTools], contextLength: 128_000, supportsTools: true),
                CatalogModel(id: "x/no-tools", uses: [.chat], contextLength: 128_000, supportsTools: false),
            ])],
            keyed: [.openRouter]
        )
        let section = try XCTUnwrap(env.resolver.sections(for: .agent).first)

        XCTAssertEqual(section.notSupportedSummary, "Not supported yet: x/no-tools (no tool support)")
        XCTAssertEqual(section.options.map(\.model), ["anthropic/claude-sonnet-5.5", "x/with-tools"])
        XCTAssertEqual(section.options.map(\.state), [.verified, .new])
    }

    func test_small_context_is_not_supported_for_agent_and_notes() throws {
        let env = try makeEnv(
            snapshots: [.openRouter: fresh([CatalogModel(id: "x/tiny", uses: [.chat, .chatWithTools], contextLength: 8_000, supportsTools: true)])],
            keyed: [.openRouter]
        )
        for feature in [AIFeature.agent, .meetingNotes] {
            XCTAssertEqual(
                env.resolver.verdict(model: "x/tiny", account: .openRouter, for: feature),
                .notSupported(reason: "context under 64K tokens")
            )
        }
        XCTAssertEqual(env.resolver.verdict(model: "x/tiny", account: .openRouter, for: .dropSmartCleanup), .new)
    }

    func test_soniox_meetings_offer_async_models_only() throws {
        let env = try makeEnv(snapshots: [.soniox: sonioxCatalog()], keyed: [.soniox])
        let section = try XCTUnwrap(env.resolver.sections(for: .meetings).first)

        XCTAssertEqual(section.options.map(\.model), ["stt-async-v5"])
        XCTAssertEqual(section.options.first?.hint, "with speakers")
        let summary = try XCTUnwrap(section.notSupportedSummary)
        XCTAssertTrue(summary.contains("stt-rt-v5"), summary)
        XCTAssertTrue(summary.contains("(real-time only)"), summary)
        XCTAssertFalse(section.options.contains { $0.model == "stt-rt-v4" })
    }

    func test_picker_lists_only_keyed_providers_that_support_the_feature() throws {
        let env = try makeEnv(keyed: [.soniox, .openRouter])
        let b = env.routing.addServer(name: "b-box", baseURL: "http://b:8000/v1")
        let a = env.routing.addServer(name: "A-box", baseURL: "http://a:8000/v1")

        XCTAssertEqual(
            env.resolver.sections(for: .dropFast).map(\.account),
            [.soniox, .server(a.id), .server(b.id)]
        )
        XCTAssertEqual(
            env.resolver.sections(for: .dropSmartCleanup).map(\.account),
            [.openRouter, .server(a.id), .server(b.id)]
        )
        XCTAssertEqual(env.resolver.sections(for: .agent).map(\.account), [.openRouter])
        XCTAssertEqual(env.resolver.sections(for: .dropFast).first?.title, "Soniox")
        XCTAssertEqual(env.resolver.sections(for: .dropFast).dropFirst().first?.title, "A-box")
    }

    func test_missing_provider_hint_lists_providers_for_the_feature() throws {
        let env = try makeEnv()
        XCTAssertEqual(env.resolver.missingProviderHint(for: .agent), "Add a key for OpenRouter")
        XCTAssertEqual(
            env.resolver.missingProviderHint(for: .dropFast),
            "Add a key for Soniox, Deepgram, ElevenLabs or an OpenAI-compatible server"
        )
        env.addKey(.soniox)
        XCTAssertNil(env.resolver.missingProviderHint(for: .dropFast))
    }

    func test_rejected_key_shows_key_problem() throws {
        let env = try makeEnv(snapshots: [.soniox: sonioxCatalog()], keyed: [.soniox])
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        XCTAssertEqual(env.resolver.status(for: .dropFast), .ok)

        env.keyStatuses.set(.rejected(.invalidKey), for: .soniox, at: Date())
        XCTAssertEqual(env.resolver.status(for: .dropFast), .keyProblem)

        let keyless = try makeEnv()
        keyless.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        XCTAssertEqual(keyless.resolver.status(for: .dropFast), .notSet)
        XCTAssertEqual(keyless.resolver.status(for: .meetings), .notSet)
    }

    func test_runtime_refusal_shows_until_the_model_changes() throws {
        let env = try makeEnv(keyed: [.openRouter])
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "vendor/refused"), for: .dropSmartCleanup)
        env.checks.recordRefusal(feature: .dropSmartCleanup, model: "vendor/refused", at: Date())
        XCTAssertEqual(
            env.resolver.status(for: .dropSmartCleanup),
            .notSupported(reason: "The provider refused this model")
        )

        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .dropSmartCleanup)
        XCTAssertEqual(env.resolver.status(for: .dropSmartCleanup), .ok)
    }

    func test_failed_probe_and_reasoning_hint() throws {
        let env = try makeEnv(
            snapshots: [.openRouter: fresh([
                CatalogModel(id: "x/thinker", uses: [.chat], reasoning: OpenRouterReasoningCapabilities(mandatory: true, supportedEfforts: nil)),
                CatalogModel(id: "x/broken", uses: [.chat]),
            ])],
            keyed: [.openRouter]
        )
        env.checks.store(
            .failed(reason: "answered 400"),
            for: ModelCheckKey(account: "openRouter", model: "x/broken", use: .chat),
            adapterVersion: 1, at: Date()
        )
        XCTAssertEqual(
            env.resolver.verdict(model: "x/broken", account: .openRouter, for: .dropSmartCleanup),
            .notSupported(reason: "answered 400")
        )
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "x/broken"), for: .dropSmartCleanup)
        XCTAssertEqual(env.resolver.status(for: .dropSmartCleanup), .notSupported(reason: "answered 400"))

        let options = try XCTUnwrap(env.resolver.sections(for: .dropSmartCleanup).first).options
        XCTAssertEqual(options.first { $0.model == "x/thinker" }?.hint, "always reasons, slower")
        XCTAssertNil(options.first { $0.model == "google/gemini-3.8-flash" }?.hint)
    }

    func test_summary_names_at_most_three_per_reason() throws {
        let models = ["a", "b", "c", "d", "e"].map { CatalogModel(id: "x/\($0)", uses: [.chat], supportsTools: false) }
        let env = try makeEnv(snapshots: [.openRouter: fresh(models)], keyed: [.openRouter])
        let section = try XCTUnwrap(env.resolver.sections(for: .agent).first)

        XCTAssertEqual(section.notSupportedSummary, "Not supported yet: x/a, x/b, x/c +2 (no tool support)")
    }
}
