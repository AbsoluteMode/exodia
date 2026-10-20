import CryptoKit
import XCTest
@testable import Sidekey

@MainActor
final class CaseDopplerViewModelTests: XCTestCase {
    func test_import_is_one_encrypted_save_and_failure_keeps_service_payload() async throws {
        let store = ImportStore()
        let importer = ImportFixture()
        let service = CaseVaultService(store: store, keyProvider: ImportKeys())
        let vm = CaseViewModel(service: service, authenticator: ImportAuth(), doppler: importer)
        try await vm.unlock()
        store.rejectSave = true
        let original = service.payload
        do {
            _ = try await vm.importFromDoppler()
            XCTFail("Expected save failure")
        } catch { }
        XCTAssertEqual(service.payload, original)
        XCTAssertFalse(vm.isImporting)
        XCTAssertFalse(vm.isSystemInteractionActive)
        store.rejectSave = false
        let result = try await vm.importFromDoppler()
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(store.successfulSaves, 1)
        XCTAssertEqual(vm.projectSections.first { $0.name == "demo / dev" }?.keyCount, 1)
    }

    func test_lock_during_fetch_prevents_commit_and_releases_busy_state() async throws {
        let store = ImportStore()
        let importer = ImportFixture()
        let service = CaseVaultService(store: store, keyProvider: ImportKeys())
        let vm = CaseViewModel(service: service, authenticator: ImportAuth(), doppler: importer)
        try await vm.unlock()
        importer.duringFetch = {
            XCTAssertTrue(vm.isImporting)
            XCTAssertTrue(vm.isSystemInteractionActive)
            XCTAssertTrue(vm.holdsPanelOpen)
            vm.lock()
        }
        do {
            _ = try await vm.importFromDoppler()
            XCTFail("Expected locked error")
        } catch { XCTAssertEqual(error as? CaseViewModelError, .locked) }
        XCTAssertEqual(store.successfulSaves, 0)
        XCTAssertFalse(vm.isImporting)
        XCTAssertFalse(vm.isSystemInteractionActive)
    }
}

@MainActor
private final class ImportFixture: CaseDopplerImporting {
    var duringFetch: () -> Void = {}
    func fetch() async throws -> CaseDopplerSnapshot {
        duringFetch()
        return .init(configurations: [.init(project: "demo", config: "dev", secrets: ["KEY": "synthetic-fixture"])])
    }
}

private final class ImportStore: CaseVaultStoring {
    var rejectSave = false
    var successfulSaves = 0
    func load(using key: SymmetricKey) throws -> CaseVaultPayload { CaseVaultPayload() }
    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws {
        if rejectSave { throw CaseDopplerImportError.fetchFailed }
        successfulSaves += 1
    }
    func reset() throws {}
}

private struct ImportKeys: CaseVaultKeyProviding {
    func readOrCreateKey() throws -> SymmetricKey { SymmetricKey(size: .bits256) }
}

private struct ImportAuth: CaseAuthenticating {
    func authenticate(reason: String) async throws {}
}
