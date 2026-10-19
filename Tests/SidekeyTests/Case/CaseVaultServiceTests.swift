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
}

private final class MemoryStore: CaseVaultStoring {
    var payload: CaseVaultPayload
    var loadError: Error?
    private(set) var saveCount = 0
    init(payload: CaseVaultPayload) { self.payload = payload }
    func load(using key: SymmetricKey) throws -> CaseVaultPayload {
        if let loadError { throw loadError }
        return payload
    }
    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws {
        saveCount += 1
        self.payload = payload
        loadError = nil
    }
    func reset() throws { loadError = CaseVaultStoreError.missingFile }
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
