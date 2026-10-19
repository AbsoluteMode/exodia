import Combine
import XCTest
@testable import Sidekey

@MainActor
final class APIAndModelsViewModelTests: XCTestCase {
    // MARK: - Fakes

    private final class FakeChecker: ProviderKeyChecking, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [ProviderAccount: KeyStatus] = [:]
        private var log: [(account: ProviderAccount, paid: Bool)] = []

        func set(_ status: KeyStatus, for account: ProviderAccount) {
            lock.lock(); defer { lock.unlock() }
            results[account] = status
        }

        var calls: [(account: ProviderAccount, paid: Bool)] {
            lock.lock(); defer { lock.unlock() }
            return log
        }

        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus {
            lock.withLock {
                log.append((account, allowPaidProbe))
                return results[account] ?? .valid
            }
        }
    }

    private final class FakeProbe: ModelProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var next: ProbeOutcome = .passed
        private var log: [String] = []

        func answer(_ outcome: ProbeOutcome) {
            lock.lock(); defer { lock.unlock() }
            next = outcome
        }

        var probedModels: [String] {
            lock.lock(); defer { lock.unlock() }
            return log
        }

        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome {
            lock.withLock {
                log.append(route.model)
                return next
            }
        }
    }

    /// Every refresh fails as if offline: the cache stays as seeded.
    private struct OfflineFetcher: ModelCatalogFetching {
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
            throw CatalogFetchError.offline
        }
    }

    private struct UnreadableTokenStore: TokenStore {
        struct Failure: Error {}
        func save(_ token: String) throws {}
        func read() throws -> String? { throw Failure() }
        func delete() throws {}
    }

    @MainActor private final class Env {
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        let catalogs: ModelCatalogStore
        let checks: ModelCheckStore
        let keyStatuses: KeyStatusStore
        let checker = FakeChecker()
        let probe = FakeProbe()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var language: String?

        init(routing: AIRoutingStore, keys: ProviderKeyStore, catalogs: ModelCatalogStore,
             checks: ModelCheckStore, keyStatuses: KeyStatusStore) {
            self.routing = routing
            self.keys = keys
            self.catalogs = catalogs
            self.checks = checks
            self.keyStatuses = keyStatuses
        }

        func addKey(_ account: ProviderAccount) {
            if let name = account.keychainAccount(in: routing) { try? keys.save("key", account: name) }
        }

        func lookup(_ account: ProviderAccount) -> ProviderKeyStore.KeyLookup? {
            account.keychainAccount(in: routing).map { keys.lookup(account: $0) }
        }

        func makeViewModel() -> APIAndModelsViewModel {
            let now = self.now
            return APIAndModelsViewModel(
                routing: routing, keys: keys, catalogs: catalogs, checks: checks, keyStatuses: keyStatuses,
                keyChecker: checker, probe: probe, now: { now },
                inputLanguage: { [unowned self] in self.language }
            )
        }
    }

    private func makeEnv(
        snapshots: [ProviderAccount: CatalogSnapshot] = [:],
        keyed: [ProviderAccount] = [],
        unreadable: Set<String> = []
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

        let box = InMemoryTokenStore.Box()
        let env = Env(
            routing: AIRoutingStore(defaults: defaults),
            keys: ProviderKeyStore(makeStore: { name in
                unreadable.contains(name) ? UnreadableTokenStore() as any TokenStore : InMemoryTokenStore(account: name, box: box)
            }),
            catalogs: ModelCatalogStore(fileURL: file, fetcher: OfflineFetcher()),
            checks: ModelCheckStore(defaults: defaults),
            keyStatuses: KeyStatusStore(defaults: defaults)
        )
        for account in keyed { env.addKey(account) }
        return env
    }

    private func fresh(_ models: [CatalogModel]) -> CatalogSnapshot {
        CatalogSnapshot(models: models, fetchedAt: Date(), lastRefreshFailed: false, limited: false)
    }

    private func row(_ feature: AIFeature, in vm: APIAndModelsViewModel) -> FeatureRow? {
        vm.rows.first { $0.feature == feature }
    }

    // MARK: - Chips

    func test_chips_show_keyed_providers_and_servers_only() throws {
        let env = try makeEnv(keyed: [.soniox, .openRouter], unreadable: [BYOKKeyStore.account(for: .elevenLabs)])
        let server = env.routing.addServer(name: "Lab", baseURL: "http://10.0.0.2:8000/v1")
        env.keyStatuses.set(.valid, for: .soniox, at: env.now)
        env.keyStatuses.set(.rejected(.outOfCredit), for: .openRouter, at: env.now)

        let vm = env.makeViewModel()

        XCTAssertEqual(vm.chips.map(\.account), [.soniox, .elevenLabs, .openRouter, .server(server.id)])
        XCTAssertEqual(vm.chips[0], KeyChip(account: .soniox, title: "Soniox", dot: .green, statusText: "Key works", checkedAt: env.now))
        XCTAssertEqual(vm.chips[1].dot, .red, "an unreadable key is a key problem, never no key")
        XCTAssertEqual(vm.chips[2].dot, .red)
        XCTAssertEqual(vm.chips[2].statusText, "Out of credit or key limit reached")
        XCTAssertEqual(vm.chips[3].title, "Lab")
        XCTAssertEqual(vm.chips[3].dot, .yellow)
        XCTAssertEqual(vm.addableKinds, [.deepgram, .anthropic, .openAICompatible])
    }

    // MARK: - Adding keys

    func test_add_key_proposes_but_never_assigns() async throws {
        let env = try makeEnv()
        let vm = env.makeViewModel()

        let error = await vm.addKey("  sk-soniox  ", kind: .soniox)

        XCTAssertNil(error)
        XCTAssertEqual(env.lookup(.soniox), .key("sk-soniox"))
        XCTAssertTrue(env.checker.calls.allSatisfy { $0.paid })
        XCTAssertEqual(env.checker.calls.map(\.account), [.soniox])
        for feature in AIFeature.allCases {
            XCTAssertNil(env.routing.route(for: feature), "\(feature) must not be assigned by adding a key")
        }
        XCTAssertEqual(env.keyStatuses.record(for: .soniox)?.status, .valid)
        XCTAssertEqual(vm.proposal?.title, "Use Soniox for")
        XCTAssertEqual(vm.proposal?.items, [
            AssignItem(feature: .dropFast, account: .soniox, model: "stt-rt-v5"),
            AssignItem(feature: .dropSmart, account: .soniox, model: "stt-rt-v5"),
            AssignItem(feature: .meetings, account: .soniox, model: "stt-async-v5"),
            AssignItem(feature: .agentVoice, account: .soniox, model: "stt-rt-v5"),
            AssignItem(feature: .voiceSearch, account: .soniox, model: "stt-rt-v5"),
            AssignItem(feature: .subtitlesAudio, account: .soniox, model: "stt-rt-v5"),
        ])
    }

    func test_rejected_key_is_not_saved() async throws {
        let env = try makeEnv()
        env.checker.set(.rejected(.invalidKey), for: .soniox)
        let vm = env.makeViewModel()

        let error = await vm.addKey("sk-wrong", kind: .soniox)

        XCTAssertEqual(error, "Key not accepted. Regional keys aren't supported yet.")
        XCTAssertEqual(env.lookup(.soniox), .absent)
        XCTAssertNil(env.keyStatuses.record(for: .soniox))
        XCTAssertTrue(vm.chips.isEmpty)
        XCTAssertNil(vm.proposal)
        XCTAssertEqual(vm.addableKinds.first, .soniox)
    }

    func test_add_server_refuses_bad_input_and_stores_nothing() async throws {
        let env = try makeEnv()
        let vm = env.makeViewModel()

        for (name, url) in [("", "http://a:1"), ("Lab", "ftp://host/v1"), ("Lab", "http:///v1"),
                            ("Lab", "https://user:pass@host/v1"), ("Lab", "not a url")] {
            let error = await vm.addServer(name: name, baseURL: url, key: nil)
            XCTAssertNotNil(error, "\(name) \(url)")
        }
        let blank = await vm.addKey("   ", kind: .deepgram)
        XCTAssertNotNil(blank)
        XCTAssertTrue(env.routing.state.servers.isEmpty)
        XCTAssertTrue(env.checker.calls.isEmpty)

        let added = await vm.addServer(name: "  Lab  ", baseURL: " http://10.0.0.2:8000/v1 ", key: "  ")
        XCTAssertNil(added)
        XCTAssertEqual(env.routing.state.servers.map(\.name), ["Lab"])
        XCTAssertEqual(env.routing.state.servers.map(\.baseURL), ["http://10.0.0.2:8000/v1"])
        let server = try XCTUnwrap(env.routing.state.servers.first)
        XCTAssertEqual(env.keys.lookup(account: server.keyAccount), .absent, "a blank key field means keyless")
    }

    func test_apply_proposal_assigns_only_checked_features() async throws {
        let env = try makeEnv()
        let vm = env.makeViewModel()
        _ = await vm.addKey("sk-soniox", kind: .soniox)

        vm.applyProposal(selected: [.dropFast, .meetings])

        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .soniox, model: "stt-rt-v5"))
        XCTAssertEqual(env.routing.route(for: .meetings), FeatureRoute(account: .soniox, model: "stt-async-v5"))
        XCTAssertNil(env.routing.route(for: .dropSmart))
        XCTAssertNil(env.routing.route(for: .agentVoice))
        XCTAssertNil(env.probe.probedModels.first, "registry models are assigned without a probe")
        XCTAssertNil(vm.proposal)
    }

    // MARK: - Removing keys (Review Focus 3)

    func test_remove_key_unsets_features_and_reassigns_nothing() throws {
        let env = try makeEnv(snapshots: [.soniox: fresh([CatalogModel(id: "stt-rt-v5", uses: [.realtimeSTT])])],
                              keyed: [.soniox, .deepgram])
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropSmart)
        env.routing.setRoute(FeatureRoute(account: .deepgram, model: "nova-3"), for: .meetings)
        env.keyStatuses.set(.valid, for: .soniox, at: env.now)
        let vm = env.makeViewModel()

        XCTAssertEqual(vm.featuresUsing(.soniox), [.dropFast, .dropSmart])
        vm.remove(.soniox)

        XCTAssertEqual(env.lookup(.soniox), .absent)
        XCTAssertNil(env.routing.route(for: .dropFast))
        XCTAssertNil(env.routing.route(for: .dropSmart))
        XCTAssertEqual(env.routing.route(for: .meetings), FeatureRoute(account: .deepgram, model: "nova-3"))
        XCTAssertFalse(AIFeature.allCases.contains { env.routing.route(for: $0)?.account == .deepgram && $0 != .meetings })
        XCTAssertNil(env.keyStatuses.record(for: .soniox))
        XCTAssertNil(env.catalogs.snapshot(for: .soniox))
        XCTAssertNil(vm.proposal)
        XCTAssertEqual(row(.dropFast, in: vm)?.status, .notSet)
        XCTAssertEqual(row(.dropFast, in: vm)?.selectionLabel, "Choose a model")
        XCTAssertEqual(vm.chips.map(\.account), [.deepgram])
    }

    // MARK: - Picking a model

    private func sonioxWithNewModel() throws -> Env {
        let env = try makeEnv(
            snapshots: [.soniox: fresh([
                CatalogModel(id: "stt-rt-v5", uses: [.realtimeSTT]),
                CatalogModel(id: "stt-rt-v6", uses: [.realtimeSTT]),
            ])],
            keyed: [.soniox]
        )
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        return env
    }

    func test_new_model_is_assigned_after_a_passed_probe() async throws {
        let env = try sonioxWithNewModel()
        let vm = env.makeViewModel()
        XCTAssertEqual(row(.dropFast, in: vm)?.selectionLabel, "Soniox · stt-rt-v5")

        await vm.select(model: "stt-rt-v6", account: .soniox, for: .dropFast)

        XCTAssertEqual(env.probe.probedModels, ["stt-rt-v6"])
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .soniox, model: "stt-rt-v6"))
        XCTAssertEqual(row(.dropFast, in: vm)?.status, .ok)
        XCTAssertEqual(row(.dropFast, in: vm)?.isChecking, false)
        XCTAssertNil(row(.dropFast, in: vm)?.message)
    }

    func test_failed_probe_keeps_the_previous_model_and_says_why() async throws {
        let env = try sonioxWithNewModel()
        env.probe.answer(.failed(reason: "no partial results"))
        let vm = env.makeViewModel()

        await vm.select(model: "stt-rt-v6", account: .soniox, for: .dropFast)

        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .soniox, model: "stt-rt-v5"))
        XCTAssertEqual(row(.dropFast, in: vm)?.message, "no partial results")
        XCTAssertEqual(row(.dropFast, in: vm)?.isChecking, false)
    }

    func test_offline_probe_keeps_the_previous_model() async throws {
        let env = try sonioxWithNewModel()
        env.probe.answer(.inconclusive(reason: "offline"))
        let vm = env.makeViewModel()

        await vm.select(model: "stt-rt-v6", account: .soniox, for: .dropFast)

        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .soniox, model: "stt-rt-v5"))
        XCTAssertEqual(row(.dropFast, in: vm)?.message, "Couldn't check: offline")
        XCTAssertNil(env.checks.record(for: ModelCheckKey(account: "soniox", model: "stt-rt-v6", use: .realtimeSTT)))
    }

    /// A stored probe failure is not a ban: picking the model again probes it
    /// again, and a pass assigns it (final review I1).
    func test_picking_a_model_with_a_stored_failure_probes_it_again() async throws {
        let env = try sonioxWithNewModel()
        let key = ModelCheckKey(account: "soniox", model: "stt-rt-v6", use: .realtimeSTT)
        env.checks.store(.failed(reason: "Provider refused: provider"), for: key, adapterVersion: 1, at: env.now)
        let vm = env.makeViewModel()

        await vm.select(model: "stt-rt-v6", account: .soniox, for: .dropFast)

        XCTAssertEqual(env.probe.probedModels, ["stt-rt-v6"])
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .soniox, model: "stt-rt-v6"))
        XCTAssertEqual(env.checks.record(for: key)?.outcome, .passed)
        XCTAssertEqual(row(.dropFast, in: vm)?.status, .ok)
    }

    /// A registry model that once failed is probed on the next pick too, so the
    /// stored failure does not keep showing after it is assigned.
    func test_picking_a_registry_model_with_a_stored_failure_probes_it_again() async throws {
        let env = try sonioxWithNewModel()
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v6"), for: .dropFast)
        let key = ModelCheckKey(account: "soniox", model: "stt-rt-v5", use: .realtimeSTT)
        env.checks.store(.failed(reason: "Provider refused: provider"), for: key, adapterVersion: 1, at: env.now)
        let vm = env.makeViewModel()

        await vm.select(model: "stt-rt-v5", account: .soniox, for: .dropFast)

        XCTAssertEqual(env.probe.probedModels, ["stt-rt-v5"])
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .soniox, model: "stt-rt-v5"))
        XCTAssertEqual(row(.dropFast, in: vm)?.status, .ok)
    }

    /// A runtime refusal clears on a passed Check now and on picking the model
    /// again (final review I2).
    func test_refusal_clears_on_a_passed_check_and_on_a_new_pick() async throws {
        let env = try makeEnv(keyed: [.openRouter])
        let model = "google/gemini-3.8-flash"
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: model), for: .dropSmartCleanup)
        env.checks.recordRefusal(feature: .dropSmartCleanup, model: model, at: env.now)
        let vm = env.makeViewModel()
        XCTAssertEqual(row(.dropSmartCleanup, in: vm)?.status, .notSupported(reason: ModelStatusResolver.refusedReason))

        await vm.checkNow(.dropSmartCleanup)
        XCTAssertNil(env.checks.refusedModel(for: .dropSmartCleanup))
        XCTAssertEqual(row(.dropSmartCleanup, in: vm)?.status, .ok)

        env.checks.recordRefusal(feature: .dropSmartCleanup, model: model, at: env.now)
        await vm.select(model: model, account: .openRouter, for: .dropSmartCleanup)
        XCTAssertNil(env.checks.refusedModel(for: .dropSmartCleanup))
        XCTAssertEqual(row(.dropSmartCleanup, in: vm)?.status, .ok)
    }

    func test_switch_group_moves_all_four_features_to_stt_rt_v5() async throws {
        let env = try makeEnv(
            snapshots: [.soniox: fresh([
                CatalogModel(id: "stt-rt-v5", uses: [.realtimeSTT]),
                CatalogModel(id: "stt-rt-v4", uses: [.realtimeSTT], aliasOf: "stt-rt-v5"),
            ])],
            keyed: [.soniox]
        )
        let realtime: [AIFeature] = [.dropFast, .dropSmart, .agentVoice, .voiceSearch]
        for feature in realtime {
            env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v4"), for: feature)
        }
        let vm = env.makeViewModel()
        let group = try XCTUnwrap(vm.aliasGroups.first)
        XCTAssertEqual(group.features, realtime)

        await vm.apply(group)

        for feature in realtime {
            XCTAssertEqual(env.routing.route(for: feature), FeatureRoute(account: .soniox, model: "stt-rt-v5"))
        }
        XCTAssertTrue(env.probe.probedModels.isEmpty)
        XCTAssertTrue(vm.aliasGroups.isEmpty)
    }

    // MARK: - Opening the tab

    func test_opening_the_tab_runs_only_free_checks_older_than_a_day() async throws {
        let env = try makeEnv(keyed: [.soniox, .deepgram, .openRouter])
        env.keyStatuses.set(.valid, for: .soniox, at: env.now.addingTimeInterval(-3_600))
        env.keyStatuses.set(.valid, for: .deepgram, at: env.now.addingTimeInterval(-2 * 86_400))
        let vm = env.makeViewModel()

        await vm.onAppear()

        XCTAssertEqual(Set(env.checker.calls.map(\.account)), [.deepgram, .openRouter])
        XCTAssertEqual(env.checker.calls.count, 2)
        XCTAssertTrue(env.checker.calls.allSatisfy { !$0.paid })
        XCTAssertEqual(env.keyStatuses.record(for: .openRouter)?.checkedAt, env.now)
    }

    // MARK: - Banner

    func test_banner_counts_unset_features_only_when_a_key_exists() throws {
        let env = try makeEnv()
        XCTAssertNil(env.makeViewModel().unsetBanner)

        env.addKey(.soniox)
        XCTAssertEqual(env.makeViewModel().unsetBanner, "10 features have no model")

        for feature in AIFeature.allCases where feature != .dropFast {
            env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: feature)
        }
        XCTAssertEqual(env.makeViewModel().unsetBanner, "1 feature has no model")

        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        XCTAssertNil(env.makeViewModel().unsetBanner)
    }

    // MARK: - Deepgram input language (PR #35)

    func test_deepgram_row_warns_when_the_input_language_does_not_fit() async throws {
        let env = try makeEnv(keyed: [.deepgram])
        let route = FeatureRoute(account: .deepgram, model: "nova-3")
        env.routing.setRoute(route, for: .agentVoice)
        env.language = "cy"
        let vm = env.makeViewModel()

        XCTAssertEqual(row(.agentVoice, in: vm)?.message,
                       "This Deepgram model doesn't support the current input language. Pick another model or input language.")

        env.language = "ru"
        let updated = expectation(description: "rows recomputed")
        let watch = vm.$rows.dropFirst().sink { rows in
            if rows.first(where: { $0.feature == .agentVoice })?.message == nil { updated.fulfill() }
        }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        await fulfillment(of: [updated], timeout: 2)
        watch.cancel()

        XCTAssertNil(row(.agentVoice, in: vm)?.message)
        XCTAssertEqual(env.routing.route(for: .agentVoice), route)
    }
}
