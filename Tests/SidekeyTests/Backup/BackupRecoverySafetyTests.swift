import CryptoKit
import XCTest
@testable import Sidekey

/// Failures outside the normal happy path: a backup must never exchange an
/// unreadable generation or an interrupted restore for a success badge.
@MainActor
final class BackupRecoverySafetyTests: XCTestCase {
    private var profiles: [ArtifactBackupTestProfile] = []
    private var stores: [MeetingsStore] = []
    override func tearDown() async throws {
        for store in stores { await store.close() }; stores.removeAll()
        profiles.forEach { $0.tearDown() }; profiles.removeAll()
    }
    private func profile() throws -> ArtifactBackupTestProfile {
        let result = try ArtifactBackupTestProfile(); profiles.append(result); return result
    }
    private func workspaceArchive() async throws -> (URL, Data) {
        let source = try profile()
        try source.write("source instructions", to: source.locations.agentMemory)
        let file = source.root.appendingPathComponent("archive.exodiabackup"), key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment()).createArchive(at: file, key: key, sections: [.workspace])
        return (file, key)
    }
    private func arm(_ file: URL, key: Data, target: ArtifactBackupTestProfile, sections: Set<ArtifactBackupSection> = [.workspace]) async throws {
        try await ArtifactBackupEngine(environment: target.environment()).stageRestore(from: file, key: key, sections: sections)
    }

    func testReadyMeetingWithMissingNoteCannotProduceACompleteBackup() async throws {
        let source = try profile()
        let store = try MeetingsStore(rootDirectory: source.locations.meetingsCatalog); stores.append(store)
        let id = UUID(), date = Date()
        try await store.insert(meta: MeetingMetaWithLocalState(id: id, startedAt: date, endedAt: date, durationSeconds: 1,
            title: "Synthetic ready meeting", syncStatus: .new, serverVersion: 1, createdAt: date), markdown: "required note")
        try FileManager.default.removeItem(at: source.locations.meetingsCatalog.appendingPathComponent(id.uuidString + ".md"))
        let engine = ArtifactBackupEngine(environment: source.environment(meetings: store))
        do {
            _ = try await engine.createArchive(at: source.root.appendingPathComponent("broken.exodiabackup"), key: ArtifactBackupTestKeys.make(), sections: [.meetings])
            XCTFail("A missing saved note must fail the complete backup")
        } catch { }
    }

    func testOwnedNotificationWorkerBytesSurviveCleanProfileRecovery() async throws {
        let source = try profile(), target = try profile()
        let worker = source.locations.notifyRoot.appendingPathComponent("workers/telegram.py")
        try source.write("# synthetic local worker bytes", to: worker)
        try source.write("source instructions", to: source.locations.agentMemory)
        let file = source.root.appendingPathComponent("archive.exodiabackup"), key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment()).createArchive(at: file, key: key, sections: [.workspace])
        try await arm(file, key: key, target: target)
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
        XCTAssertEqual(target.contents(of: target.locations.notifyRoot.appendingPathComponent("workers/telegram.py")), "# synthetic local worker bytes")
    }

    func testRollbackRestoresARenameThatCrashedBeforeItsCompletionFlagWasWritten() async throws {
        let (file, key) = try await workspaceArchive(), target = try profile()
        try target.write("the only original copy", to: target.locations.agentMemory)
        try await arm(file, key: key, target: target)
        let previous = target.locations.pendingRestoreRoot.appendingPathComponent("previous/0-AGENTS.md")
        try FileManager.default.createDirectory(at: previous.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: target.locations.agentMemory, to: previous)
        let plan = try JSONDecoder.artifactBackup.decode(ArtifactRestorePlan.self, from: Data(contentsOf: target.locations.pendingRestoreRoot.appendingPathComponent("plan.json")))
        let journal: [String: Any] = ["id": plan.id.uuidString, "startedAt": "2026-10-19T12:00:00Z",
            "steps": [["target": target.locations.agentMemory.path, "backup": previous.path, "movedAside": false]]]
        try target.write(JSONSerialization.data(withJSONObject: journal), to: target.locations.pendingRestoreRoot.appendingPathComponent("journal.json"))
        _ = try? ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
        XCTAssertEqual(target.contents(of: target.locations.agentMemory), "the only original copy")
    }

    func testUnreadableJournalNeverDeletesTheOnlyPreviousCopy() async throws {
        let (file, key) = try await workspaceArchive(), target = try profile()
        try await arm(file, key: key, target: target)
        let previous = target.locations.pendingRestoreRoot.appendingPathComponent("previous/0-AGENTS.md")
        try target.write("the only original copy", to: previous)
        let journal = target.locations.pendingRestoreRoot.appendingPathComponent("journal.json")
        try target.write("{ damaged journal", to: journal)
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment()))
        XCTAssertEqual(target.contents(of: previous), "the only original copy")
        XCTAssertTrue(target.exists(journal), "Recovery evidence must remain until rollback succeeds")
    }

    func testRollbackRemovesNewFilesWhenTheTargetDidNotExistBefore() async throws {
        let (file, key) = try await workspaceArchive(), target = try profile()
        try await arm(file, key: key, target: target)
        var faults = ArtifactBackupFaults(); faults.beforeCommit = { throw ArtifactBackupError.writeFailed }
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment(faults: faults)))
        XCTAssertFalse(target.exists(target.locations.agentMemory), "A failed restore must not leave an imported instruction file active")
    }

    private struct RefusingCaseKeys: ArtifactCaseKeyProviding {
        func existingVaultKey() throws -> SymmetricKey? { nil }
        func vaultKeyForRestore() throws -> SymmetricKey { throw ArtifactBackupError.keyUnavailable }
    }
    func testFailureAfterProviderKeysWereAppliedRestoresTheirPreviousValues() async throws {
        var source = try profile(), target = try profile()
        let account = "byok.soniox.api_key"
        source.addCredential(account, "synthetic-source-key"); target.addCredential(account, "synthetic-original-key")
        let caseKey = try source.caseKeys.vaultKeyForRestore()
        try CaseVaultStore(fileURL: source.locations.caseVault).save(CaseVaultPayload(secrets: [], values: [], groups: []), using: caseKey)
        let file = source.root.appendingPathComponent("archive.exodiabackup"), key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment()).createArchive(at: file, key: key, sections: [.credentials, .caseVault])
        var environment = target.environment(); environment.caseVaultKeys = RefusingCaseKeys()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: file, key: key, sections: [.credentials, .caseVault])
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: environment))
        XCTAssertEqual(try target.credentialStores[account]?.read(), "synthetic-original-key")
    }
}
