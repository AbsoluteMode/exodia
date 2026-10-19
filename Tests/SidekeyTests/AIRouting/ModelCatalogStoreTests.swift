import XCTest
@testable import Sidekey

private final class FakeCatalogFetcher: ModelCatalogFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[CatalogModel], CatalogFetchError>]
    private var count = 0

    init(_ results: [Result<[CatalogModel], CatalogFetchError>]) {
        self.results = results
    }

    var fetchCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
        return try next().get()
    }

    private func next() -> Result<[CatalogModel], CatalogFetchError> {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return results.count > 1 ? results.removeFirst() : results[0]
    }
}

@MainActor
final class ModelCatalogStoreTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCatalogStoreTests-\(UUID().uuidString)", isDirectory: true)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("model-catalog-v1.json") }

    private func makeStore(_ fetcher: FakeCatalogFetcher) -> ModelCatalogStore {
        ModelCatalogStore(fileURL: fileURL, fetcher: fetcher, now: { [unowned self] in self.clock })
    }

    private let models = [CatalogModel(id: "stt-rt-v5", uses: [.realtimeSTT])]

    func test_offline_refresh_keeps_models_and_marks_couldnt_refresh() async {
        let fetcher = FakeCatalogFetcher([.success(models), .failure(.offline)])
        let store = makeStore(fetcher)
        await store.refresh(.soniox, apiKey: "k", server: nil)
        let fetchedAt = clock
        clock = clock.addingTimeInterval(3600)
        await store.refresh(.soniox, apiKey: "k", server: nil)

        let snapshot = store.snapshot(for: .soniox)
        XCTAssertEqual(snapshot?.models, models)
        XCTAssertEqual(snapshot?.fetchedAt, fetchedAt)
        XCTAssertEqual(snapshot?.lastRefreshFailed, true)
        XCTAssertEqual(snapshot?.isAuthoritative, false)
    }

    func test_server_error_keeps_the_cache() async {
        let fetcher = FakeCatalogFetcher([.success(models), .failure(.http(503, code: nil))])
        let store = makeStore(fetcher)
        await store.refresh(.openRouter, apiKey: nil, server: nil)
        await store.refresh(.openRouter, apiKey: nil, server: nil)

        XCTAssertEqual(store.snapshot(for: .openRouter)?.models, models)
        XCTAssertEqual(store.snapshot(for: .openRouter)?.lastRefreshFailed, true)

        let recovered = FakeCatalogFetcher([.success(models)])
        let again = makeStore(recovered)
        await again.refresh(.openRouter, apiKey: nil, server: nil)
        XCTAssertEqual(again.snapshot(for: .openRouter)?.lastRefreshFailed, false)
        XCTAssertEqual(again.snapshot(for: .openRouter)?.isAuthoritative, true)
    }

    func test_fresh_cache_is_not_refetched_within_a_day() async {
        let fetcher = FakeCatalogFetcher([.success(models)])
        let store = makeStore(fetcher)
        await store.refreshIfStale(.soniox, apiKey: "k", server: nil)
        clock = clock.addingTimeInterval(23 * 3600)
        await store.refreshIfStale(.soniox, apiKey: "k", server: nil)
        XCTAssertEqual(fetcher.fetchCount, 1)
        clock = clock.addingTimeInterval(2 * 3600)
        await store.refreshIfStale(.soniox, apiKey: "k", server: nil)
        XCTAssertEqual(fetcher.fetchCount, 2)
    }

    func test_cache_survives_relaunch() async throws {
        let fetcher = FakeCatalogFetcher([.success(models)])
        let store = makeStore(fetcher)
        await store.refresh(.soniox, apiKey: "k", server: nil)

        let relaunched = makeStore(FakeCatalogFetcher([.failure(.offline)]))
        XCTAssertEqual(relaunched.snapshot(for: .soniox), store.snapshot(for: .soniox))
        XCTAssertEqual(relaunched.snapshot(for: .soniox)?.models, models)

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("\"k\""), "the cache holds model metadata only")

        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(makeStore(fetcher).snapshots.isEmpty, "an unreadable file is an empty cache")
    }

    func test_soniox_permission_denied_marks_limited() async {
        let fetcher = FakeCatalogFetcher([.success(models), .failure(.http(403, code: nil))])
        let store = makeStore(fetcher)
        await store.refresh(.soniox, apiKey: "k", server: nil)
        await store.refresh(.soniox, apiKey: "k", server: nil)
        XCTAssertEqual(store.snapshot(for: .soniox)?.limited, true)
        XCTAssertEqual(store.snapshot(for: .soniox)?.models, models)
        XCTAssertEqual(store.snapshot(for: .soniox)?.isAuthoritative, false)

        let deepgram = makeStore(FakeCatalogFetcher([.failure(.http(403, code: "INSUFFICIENT_PERMISSIONS"))]))
        await deepgram.refresh(.deepgram, apiKey: "k", server: nil)
        XCTAssertEqual(deepgram.snapshot(for: .deepgram)?.limited, true)

        try? FileManager.default.removeItem(at: fileURL)
        let other = makeStore(FakeCatalogFetcher([.failure(.http(403, code: "SOMETHING_ELSE"))]))
        await other.refresh(.deepgram, apiKey: "k", server: nil)
        XCTAssertEqual(other.snapshot(for: .deepgram)?.limited, false)
        XCTAssertEqual(other.snapshot(for: .deepgram)?.lastRefreshFailed, true)
    }

    func test_server_without_models_endpoint_is_an_empty_valid_catalog() async {
        let id = UUID()
        let server = ServerEndpoint(id: id, name: "S", baseURL: "http://localhost:8000", keyAccount: "byok.server.x.api_key")
        let store = makeStore(FakeCatalogFetcher([.failure(.http(404, code: nil))]))
        await store.refresh(.server(id), apiKey: nil, server: server)
        let snapshot = store.snapshot(for: .server(id))
        XCTAssertEqual(snapshot?.models, [])
        XCTAssertEqual(snapshot?.lastRefreshFailed, false)
        XCTAssertNotNil(snapshot?.fetchedAt)
    }

    func test_forget_removes_the_account() async {
        let store = makeStore(FakeCatalogFetcher([.success(models)]))
        await store.refresh(.soniox, apiKey: "k", server: nil)
        store.forget(.soniox)
        XCTAssertNil(store.snapshot(for: .soniox))
        XCTAssertNil(makeStore(FakeCatalogFetcher([.failure(.offline)])).snapshot(for: .soniox))
    }
}
