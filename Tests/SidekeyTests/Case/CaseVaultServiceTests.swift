import CryptoKit
import XCTest
@testable import Sidekey

@MainActor
final class CaseVaultServiceTests: XCTestCase {
    func test_service_loads_without_touch_id() async throws {
        let auth = CountingAuthenticator()
        let store = MemoryStore(payload: CaseVaultPayload())
        let service = CaseVaultService(store: store, keyProvider: FixedKeys())
        let vm = CaseViewModel(service: service, authenticator: auth, scheduleIdleLock: { _, _ in NoopCancellable() })

        XCTAssertNil(service.payload)
        let loaded = try service.loadIfNeeded()

        XCTAssertEqual(loaded.projects.map(\.id), [CaseProject.generalID])
        XCTAssertEqual(auth.callCount, 0)
        XCTAssertFalse(vm.isUnlocked)
    }

    func test_missing_file_creates_vault_with_real_clock_general() throws {
        let store = MemoryStore(payload: CaseVaultPayload())
        store.loadError = CaseVaultStoreError.missingFile
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let service = CaseVaultService(store: store, keyProvider: FixedKeys(), now: { stamp })

        let loaded = try service.loadIfNeeded()

        XCTAssertEqual(loaded.project(CaseProject.generalID)?.createdAt, stamp)
        XCTAssertEqual(store.saveCount, 1)
    }

    func test_failed_mutation_leaves_disk_and_published_payload_untouched() throws {
        let store = MemoryStore(payload: CaseVaultPayload())
        let service = CaseVaultService(store: store, keyProvider: FixedKeys())
        try service.loadIfNeeded()

        XCTAssertThrowsError(try service.mutate { $0.projects.removeAll() }) {
            XCTAssertEqual($0 as? CaseVaultServiceError, .invalidPayload)
        }
        XCTAssertThrowsError(try service.mutate { payload in
            payload.secrets.append(CaseSecret(id: UUID(), name: "X", projectID: UUID(), description: "", copyCount: 0, lastCopiedAt: nil, createdAt: Date(), updatedAt: Date()))
        })

        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(service.payload?.projects.count, 1)
        XCTAssertTrue(service.payload?.secrets.isEmpty ?? false)
    }

    func test_mutate_saves_and_publishes() throws {
        let store = MemoryStore(payload: CaseVaultPayload())
        let service = CaseVaultService(store: store, keyProvider: FixedKeys())

        try service.mutate { $0.timedApprovalMinutes = 30 }

        XCTAssertEqual(store.payload.timedApprovalMinutes, 30)
        XCTAssertEqual(service.payload?.timedApprovalMinutes, 30)
    }

    func test_reset_is_refused_while_a_valid_vault_is_loaded() throws {
        let store = MemoryStore(payload: CaseVaultPayload())
        let service = CaseVaultService(store: store, keyProvider: FixedKeys())
        try service.loadIfNeeded()

        // A stale needsReset view must not set a readable vault aside.
        XCTAssertThrowsError(try service.reset()) {
            XCTAssertEqual($0 as? CaseVaultServiceError, .resetWhileLoaded)
        }
        XCTAssertEqual(store.resetCount, 0)
        XCTAssertNotNil(service.payload)
    }

    func test_reset_sets_unreadable_vault_aside_when_nothing_is_loaded() throws {
        let store = MemoryStore(payload: CaseVaultPayload())
        store.loadError = CaseVaultStoreError.missingFile
        let service = CaseVaultService(store: store, keyProvider: FixedKeys())

        try service.reset()

        XCTAssertEqual(store.resetCount, 1)
        XCTAssertNil(service.payload)
    }

    func test_reload_from_disk_picks_up_external_changes() throws {
        let store = MemoryStore(payload: CaseVaultPayload())
        let service = CaseVaultService(store: store, keyProvider: FixedKeys())
        try service.loadIfNeeded()
        store.payload.timedApprovalMinutes = 42

        XCTAssertEqual(try service.loadIfNeeded().timedApprovalMinutes, 15, "cached payload is reused")
        XCTAssertEqual(store.loadCount, 1)

        let reloaded = try service.reloadFromDisk()

        XCTAssertEqual(reloaded.timedApprovalMinutes, 42)
        XCTAssertEqual(service.payload?.timedApprovalMinutes, 42)
        XCTAssertEqual(store.loadCount, 2)
    }

    func test_failed_reload_forgets_cached_values() throws {
        let store = MemoryStore(payload: CaseVaultPayload())
        let service = CaseVaultService(store: store, keyProvider: FixedKeys())
        try service.loadIfNeeded()
        store.loadError = CaseVaultStoreError.invalidEnvelope

        XCTAssertThrowsError(try service.reloadFromDisk())
        XCTAssertNil(service.payload, "an unreadable disk must not leave stale values served")
    }
}

private final class MemoryStore: CaseVaultStoring {
    var payload: CaseVaultPayload
    var loadError: Error?
    private(set) var saveCount = 0
    private(set) var loadCount = 0
    private(set) var resetCount = 0
    init(payload: CaseVaultPayload) { self.payload = payload }
    func load(using key: SymmetricKey) throws -> CaseVaultPayload {
        loadCount += 1
        if let loadError { throw loadError }
        return payload
    }
    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws {
        saveCount += 1
        self.payload = payload
        loadError = nil
    }
    func reset() throws {
        resetCount += 1
        loadError = CaseVaultStoreError.missingFile
    }
}

private struct FixedKeys: CaseVaultKeyProviding {
    func readOrCreateKey() throws -> SymmetricKey { SymmetricKey(size: .bits256) }
}

private final class CountingAuthenticator: CaseAuthenticating {
    private(set) var callCount = 0
    func authenticate(reason: String) async throws { callCount += 1 }
}

private final class NoopCancellable: CaseIdleLockCancellable {
    var isCancelled = false
    func cancel() { isCancelled = true }
}
