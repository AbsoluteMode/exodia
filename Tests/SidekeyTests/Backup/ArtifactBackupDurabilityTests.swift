import CryptoKit
import XCTest
@testable import Sidekey

/// Durability of everything a restore changes outside the filesystem, and of
/// the rollback itself. Interruptions are simulated where a crash would hit,
/// not only through the ordinary error path, because the ordinary path still
/// has its in-memory state and a crash does not.
@MainActor
final class ArtifactBackupDurabilityTests: XCTestCase {
    private var profiles: [ArtifactBackupTestProfile] = []
    private var openMeetingStores: [MeetingsStore] = []
    private var permissionFixups: [URL] = []

    override func tearDown() async throws {
        for url in permissionFixups {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        permissionFixups.removeAll()
        for store in openMeetingStores { await store.close() }
        openMeetingStores.removeAll()
        profiles.forEach { $0.tearDown() }
        profiles.removeAll()
    }

    private let sonioxAccount = "byok.soniox.api_key"
    private let providerKey = "sidekey.models.byokProvider"

    private func profile() throws -> ArtifactBackupTestProfile {
        let result = try ArtifactBackupTestProfile()
        profiles.append(result)
        return result
    }

    /// Settings and one provider key, which is what a metadata rollback has
    /// to put back.
    private func metadataArchive() async throws -> (URL, Data) {
        var source = try profile()
        source.defaults.set("soniox", forKey: providerKey)
        source.addCredential(sonioxAccount, "synthetic-source-key")
        let url = source.root.appendingPathComponent("metadata.exodiabackup")
        let key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment())
            .createArchive(at: url, key: key, sections: [.settings, .credentials])
        return (url, key)
    }

    private func workspaceArchive() async throws -> (URL, Data) {
        let source = try profile()
        try source.write("source instructions", to: source.locations.agentMemory)
        try source.write("source dashboard", to: source.locations.monitorRoot
            .appendingPathComponent("dashboards/source.json"))
        let url = source.root.appendingPathComponent("workspace.exodiabackup")
        let key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment())
            .createArchive(at: url, key: key, sections: [.workspace])
        return (url, key)
    }

    // MARK: - Power loss after the metadata commit

    func testPowerLossAfterKeysAndSettingsWereCommittedIsUndoneOnTheNextLaunch() async throws {
        let (archive, key) = try await metadataArchive()
        var target = try profile()
        target.defaults.set("deepgram", forKey: providerKey)
        target.addCredential(sonioxAccount, "synthetic-original-key")
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: archive, key: key, sections: [.settings, .credentials])

        var faults = ArtifactBackupFaults()
        faults.interruptAfter = { $0 == .metadata }
        do {
            _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment(faults: faults))
            XCTFail("expected the simulated interruption")
        } catch is ArtifactRestoreInterruption {
            // The process "died" here: the keys are already committed.
        }
        XCTAssertEqual(target.credentialStores[sonioxAccount]?.value, "synthetic-source-key")
        XCTAssertEqual(target.defaults.string(forKey: providerKey), "soniox")
        let root = target.locations.pendingRestoreRoot
        XCTAssertTrue(target.exists(root.appendingPathComponent("journal.json")))
        XCTAssertTrue(target.exists(root.appendingPathComponent("before-state.enc")))

        // Next launch: the durable before-state puts both back.
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: environment)) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .restoreInterrupted)
        }
        XCTAssertEqual(target.credentialStores[sonioxAccount]?.value, "synthetic-original-key")
        XCTAssertEqual(target.defaults.string(forKey: providerKey), "deepgram")
        XCTAssertEqual(ArtifactBackupEngine.lastRestoreOutcome(locations: target.locations)?.state,
                       .rolledBack)
        XCTAssertFalse(target.exists(root.appendingPathComponent("journal.json")))
        XCTAssertFalse(target.exists(root.appendingPathComponent("before-state.enc")))
        XCTAssertNil(target.pendingKeyStore.value)
    }

    func testPowerLossBeforeAnyMutationLeavesEverythingUntouched() async throws {
        let (archive, key) = try await metadataArchive()
        var target = try profile()
        target.addCredential(sonioxAccount, "synthetic-original-key")
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: archive, key: key, sections: [.settings, .credentials])
        var faults = ArtifactBackupFaults()
        faults.interruptAfter = { $0 == .beforeState }
        do {
            _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment(faults: faults))
            XCTFail("expected the simulated interruption")
        } catch is ArtifactRestoreInterruption { }
        XCTAssertEqual(target.credentialStores[sonioxAccount]?.value, "synthetic-original-key")
        XCTAssertNil(target.defaults.string(forKey: providerKey))
        // No journal was written yet, so the next launch simply applies.
        let outcome = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(outcome?.state, .applied)
        XCTAssertEqual(target.credentialStores[sonioxAccount]?.value, "synthetic-source-key")
    }

    func testCredentialReadFailureAbortsBeforeAnythingIsWritten() async throws {
        let (archive, key) = try await metadataArchive()
        var target = try profile()
        target.addCredential(sonioxAccount, "synthetic-original-key")
        target.credentialStores[sonioxAccount]?.failOnRead = true
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: archive, key: key, sections: [.settings, .credentials])
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: environment)) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .keyUnavailable)
        }
        // Nothing was written: the key still holds the target's own value and
        // no preference was applied.
        XCTAssertEqual(target.credentialStores[sonioxAccount]?.value, "synthetic-original-key")
        XCTAssertNil(target.defaults.string(forKey: providerKey))
    }

    // MARK: - Rollback failure and retry

    func testRollbackFailurePreservesEveryRecordAndSucceedsOnRetry() async throws {
        let (archive, key) = try await workspaceArchive()
        let target = try profile()
        try target.write("# My own memory", to: target.locations.agentMemory)
        // A second real checkpoint target, so the retry has to cope with one
        // target already put back and one still pending.
        try target.write("my own dashboard", to: target.locations.monitorRoot
            .appendingPathComponent("dashboards/mine.json"))
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: archive, key: key, sections: [.workspace])

        // Make the rollback's move-back fail: the parent directory is not
        // writable, so neither removing nor replacing the target can work.
        var faults = ArtifactBackupFaults()
        faults.beforeCommit = { [agent = target.locations.agentWorkspace] in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: agent.path)
            throw ArtifactBackupError.writeFailed
        }
        permissionFixups.append(target.locations.agentWorkspace)
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(
            environment: target.environment(faults: faults))) { error in
            guard case .restoreNeedsRecovery = (error as? ArtifactBackupError) else {
                return XCTFail("unexpected error \(error)")
            }
        }
        let root = target.locations.pendingRestoreRoot
        XCTAssertTrue(target.exists(root.appendingPathComponent("journal.json")),
                      "the journal is the only record of what moved")
        XCTAssertTrue(target.exists(root.appendingPathComponent("plan.json")))
        XCTAssertTrue(target.exists(root.appendingPathComponent("pending.exodiabackup")))
        XCTAssertTrue(target.exists(root.appendingPathComponent("previous")))
        XCTAssertNotNil(target.pendingKeyStore.value)
        let outcome = ArtifactBackupEngine.lastRestoreOutcome(locations: target.locations)
        XCTAssertEqual(outcome?.state, .failed)
        XCTAssertEqual(outcome?.needsRecovery, true)
        XCTAssertNotEqual(outcome?.state, .rolledBack)

        // What rollback could already put back stays put back; the rest is
        // still the only copy, kept in the checkpoint.
        XCTAssertEqual(target.contents(of: target.locations.monitorRoot
            .appendingPathComponent("dashboards/mine.json")), "my own dashboard")
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: target.locations.agentWorkspace.path)
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: environment)) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .restoreInterrupted)
        }
        XCTAssertEqual(target.contents(of: target.locations.agentMemory), "# My own memory")
        XCTAssertEqual(target.contents(of: target.locations.monitorRoot
            .appendingPathComponent("dashboards/mine.json")), "my own dashboard")
        XCTAssertFalse(target.exists(target.locations.monitorRoot
            .appendingPathComponent("dashboards/source.json")), "the restore's files must not linger")
        XCTAssertFalse(target.exists(root.appendingPathComponent("journal.json")))
        XCTAssertEqual(ArtifactBackupEngine.lastRestoreOutcome(locations: target.locations)?.state,
                       .rolledBack)
        // A third launch starts normally: the retry is idempotent and final.
        XCTAssertNil(try ArtifactBackupEngine.applyPendingRestore(environment: environment))
    }

    func testJournalFromAnotherTransactionIsNeverActedOn() async throws {
        let (archive, key) = try await workspaceArchive()
        let target = try profile()
        try target.write("# My own memory", to: target.locations.agentMemory)
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: archive, key: key, sections: [.workspace])
        let root = target.locations.pendingRestoreRoot
        let foreign = target.root.appendingPathComponent("foreign.txt")
        try target.write("not ours", to: foreign)
        let plan = try JSONDecoder.artifactBackup.decode(
            ArtifactRestorePlan.self, from: Data(contentsOf: root.appendingPathComponent("plan.json")))
        let journal = """
        {"id":"\(plan.id.uuidString)","startedAt":"2026-10-19T12:00:00Z","steps":[\
        {"backup":"","movedAside":false,"existedBefore":false,"target":"\(foreign.path)"}]}
        """
        try target.write(journal, to: root.appendingPathComponent("journal.json"))

        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: environment)) { error in
            guard case .restoreNeedsRecovery = (error as? ArtifactBackupError) else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(target.contents(of: foreign), "not ours", "a path outside the transaction is untouchable")
        XCTAssertTrue(target.exists(root.appendingPathComponent("journal.json")))
        XCTAssertEqual(ArtifactBackupEngine.lastRestoreOutcome(locations: target.locations)?.needsRecovery,
                       true)
    }

    func testUnreadableJournalNeverClaimsRollbackSucceeded() async throws {
        let (archive, key) = try await workspaceArchive()
        let target = try profile()
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: archive, key: key, sections: [.workspace])
        let root = target.locations.pendingRestoreRoot
        try target.write("{ damaged", to: root.appendingPathComponent("journal.json"))
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: environment))
        let outcome = ArtifactBackupEngine.lastRestoreOutcome(locations: target.locations)
        XCTAssertEqual(outcome?.state, .failed)
        XCTAssertEqual(outcome?.needsRecovery, true)
        XCTAssertTrue(target.exists(root.appendingPathComponent("journal.json")))
        XCTAssertTrue(target.exists(root.appendingPathComponent("plan.json")))
        XCTAssertNotNil(target.pendingKeyStore.value)
    }

    func testRepeatedLockedKeychainNeverDiscardsAnInterruptedMetadataRollback() async throws {
        let (archive, key) = try await metadataArchive()
        var target = try profile()
        target.defaults.set("deepgram", forKey: providerKey)
        target.addCredential(sonioxAccount, "original")
        let engine = ArtifactBackupEngine(environment: target.environment())
        try await engine.stageRestore(from: archive, key: key, sections: [.settings, .credentials])
        var faults = ArtifactBackupFaults()
        faults.interruptAfter = { $0 == .metadata }
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment(faults: faults)))
        target.pendingKeyStore.failOnRead = true
        for _ in 0..<5 {
            XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment()))
            XCTAssertTrue(target.exists(target.locations.pendingRestoreRoot.appendingPathComponent("before-state.enc")))
            XCTAssertTrue(target.exists(target.locations.pendingRestoreRoot.appendingPathComponent("journal.json")))
            XCTAssertNotNil(target.pendingKeyStore.value)
        }
        target.pendingKeyStore.failOnRead = false
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment()))
        XCTAssertEqual(target.defaults.string(forKey: providerKey), "deepgram")
        XCTAssertEqual(target.credentialStores[sonioxAccount]?.value, "original")
    }

    func testSavedCodeCanUnlockTheInterruptedTransactionWithoutTheOldKeychainEntry() async throws {
        let (archive, key) = try await metadataArchive()
        var target = try profile()
        target.defaults.set("deepgram", forKey: providerKey)
        target.addCredential(sonioxAccount, "original")
        try await ArtifactBackupEngine(environment: target.environment()).stageRestore(from: archive, key: key, sections: [.settings, .credentials])
        var faults = ArtifactBackupFaults()
        faults.interruptAfter = { $0 == .metadata }
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment(faults: faults)))
        try target.pendingKeyStore.delete()
        let transaction = target.environment().transaction()
        XCTAssertThrowsError(try transaction.unlockPending(with: ArtifactBackupTestKeys.make()))
        XCTAssertNil(target.pendingKeyStore.value)
        try transaction.unlockPending(with: key)
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment()))
        XCTAssertEqual(target.defaults.string(forKey: providerKey), "deepgram")
        XCTAssertEqual(target.credentialStores[sonioxAccount]?.value, "original")
    }

    func testCommittedRestoreResumesFinalizationAcrossBothCrashBoundaries() async throws {
        let (archive, key) = try await workspaceArchive()
        for boundary in [ArtifactRestoreStage.committed, .recovery] {
            let target = try profile()
            try target.write("original", to: target.locations.agentMemory)
            let engine = ArtifactBackupEngine(environment: target.environment())
            try await engine.stageRestore(from: archive, key: key, sections: [.workspace])
            var faults = ArtifactBackupFaults()
            faults.interruptAfter = { $0 == boundary }
            XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment(faults: faults)))
            let outcome = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
            XCTAssertEqual(outcome?.state, .applied)
            XCTAssertEqual(target.contents(of: target.locations.agentMemory), "source instructions")
            let checkpoint = try XCTUnwrap(engine.recoveryCheckpoint())
            let previous = checkpoint.directory.appendingPathComponent("previous")
            let originals = try FileManager.default.contentsOfDirectory(at: previous, includingPropertiesForKeys: nil)
            XCTAssertTrue(originals.contains { target.contents(of: $0) == "original" })
            XCTAssertNil(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment()))
        }
    }

    func testCheckpointKeySaveFailureKeepsTheCommittedTransactionForRetry() async throws {
        let (archive, key) = try await workspaceArchive()
        let target = try profile()
        try target.write("original", to: target.locations.agentMemory)
        let engine = ArtifactBackupEngine(environment: target.environment())
        try await engine.stageRestore(from: archive, key: key, sections: [.workspace])
        target.recoveryKeyStore.failOnSave = true
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment()))
        let root = target.locations.pendingRestoreRoot
        XCTAssertTrue(target.exists(root.appendingPathComponent("journal.json")))
        XCTAssertTrue(target.exists(root.appendingPathComponent("before-state.enc")))
        XCTAssertNotNil(target.pendingKeyStore.value)
        target.recoveryKeyStore.failOnSave = false
        XCTAssertEqual(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())?.state, .applied)
        XCTAssertNotNil(engine.recoveryCheckpoint())
    }

    func testTwoRestoresRetainBothPreviousGenerationsAndTheirKeys() async throws {
        let (archive, key) = try await workspaceArchive()
        let target = try profile()
        let engine = ArtifactBackupEngine(environment: target.environment())
        for original in ["first original", "second original"] {
            try target.write(original, to: target.locations.agentMemory)
            try await engine.stageRestore(from: archive, key: key, sections: [.workspace])
            XCTAssertEqual(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())?.state, .applied)
        }
        let directories = try FileManager.default.contentsOfDirectory(at: target.locations.recoveryRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(directories.count, 2)
        let keys = try JSONDecoder().decode([String: String].self, from: Data(try XCTUnwrap(target.recoveryKeyStore.value).utf8))
        XCTAssertEqual(Set(keys.keys), Set(directories.map(\.lastPathComponent)))
        for directory in directories { XCTAssertTrue(target.exists(directory.appendingPathComponent("before-state.enc"))) }
    }

    func testMissingOriginalCheckpointCannotBeMistakenForACompletedRollback() async throws {
        let (archive, key) = try await workspaceArchive()
        let target = try profile()
        try target.write("original", to: target.locations.agentMemory)
        try await ArtifactBackupEngine(environment: target.environment()).stageRestore(from: archive, key: key, sections: [.workspace])
        var faults = ArtifactBackupFaults()
        faults.interruptAfter = { $0 == .files }
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment(faults: faults)))
        let previous = target.locations.pendingRestoreRoot.appendingPathComponent("previous")
        let files = try FileManager.default.contentsOfDirectory(at: previous, includingPropertiesForKeys: nil)
        let original = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix("AGENTS.md") })
        try FileManager.default.removeItem(at: original)
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment()))
        XCTAssertEqual(ArtifactBackupEngine.lastRestoreOutcome(locations: target.locations)?.needsRecovery, true)
        XCTAssertTrue(target.exists(target.locations.pendingRestoreRoot.appendingPathComponent("journal.json")))
    }

    // MARK: - Retained recovery checkpoint and cancellation

    func testRecoveryCheckpointIsRetainedAcrossANewArmAndACancel() async throws {
        let (archive, key) = try await workspaceArchive()
        let target = try profile()
        try target.write("# My own memory", to: target.locations.agentMemory)
        let environment = target.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        try await engine.stageRestore(from: archive, key: key, sections: [.workspace])
        let outcome = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(outcome?.state, .applied)
        XCTAssertEqual(target.contents(of: target.locations.agentMemory), "source instructions")

        let checkpoint = try XCTUnwrap(engine.recoveryCheckpoint())
        XCTAssertGreaterThan(checkpoint.fileCount, 0)
        XCTAssertEqual(outcome?.recoveryDirectory, checkpoint.directoryPath)
        XCTAssertEqual(checkpoint.sections, [.workspace])
        // The replaced file is recoverable, not deleted.
        let preserved = checkpoint.directory.appendingPathComponent("previous")
        let names = try FileManager.default.contentsOfDirectory(atPath: preserved.path)
        XCTAssertTrue(names.contains { $0.hasSuffix("AGENTS.md") }, "\(names)")
        XCTAssertNotNil(target.recoveryKeyStore.value, "the before-state stays decryptable")

        // Arming and then cancelling another restore must not touch it.
        try await engine.stageRestore(from: archive, key: key, sections: [.workspace])
        XCTAssertNotNil(engine.plannedRestore())
        XCTAssertNotNil(engine.recoveryCheckpoint())
        XCTAssertTrue(try engine.cancelPlannedRestore())
        XCTAssertNil(engine.plannedRestore())
        XCTAssertFalse(engine.hasPendingRestore)
        XCTAssertFalse(target.exists(target.locations.pendingRestoreRoot
            .appendingPathComponent("pending.exodiabackup")))
        XCTAssertNotNil(engine.recoveryCheckpoint())
        XCTAssertFalse(try engine.cancelPlannedRestore())
        XCTAssertNil(try ArtifactBackupEngine.applyPendingRestore(environment: environment))
    }

    func testCancelRefusesWhileAnApplyIsUnfinished() async throws {
        let (archive, key) = try await workspaceArchive()
        let target = try profile()
        let environment = target.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        try await engine.stageRestore(from: archive, key: key, sections: [.workspace])
        let plan = try JSONDecoder.artifactBackup.decode(
            ArtifactRestorePlan.self,
            from: Data(contentsOf: target.locations.pendingRestoreRoot.appendingPathComponent("plan.json")))
        try target.write(#"{"id":"\#(plan.id.uuidString)","startedAt":"2026-10-19T12:00:00Z","steps":[]}"#,
                         to: target.locations.pendingRestoreRoot.appendingPathComponent("journal.json"))
        XCTAssertThrowsError(try engine.cancelPlannedRestore()) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .applyInProgress)
        }
        XCTAssertTrue(target.exists(target.locations.pendingRestoreRoot
            .appendingPathComponent("pending.exodiabackup")))
    }

    func testParkedConfigurationIsActivatedThroughTheEngineNotAHiddenRename() async throws {
        var source = try profile()
        try source.write(#"{"refreshSeconds":15,"servers":[{"id":"a","name":"A","group":"g","sshTarget":"user@host"}]}"#,
                         to: source.locations.monitorRoot.appendingPathComponent("servers.json"))
        let url = source.root.appendingPathComponent("monitor.exodiabackup")
        let key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment())
            .createArchive(at: url, key: key, sections: [.workspace])

        let target = try profile()
        let environment = target.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        try await engine.stageRestore(from: url, key: key, sections: [.workspace])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)

        let items = engine.parkedRestoredItems()
        XCTAssertEqual(items.map(\.kind), [.monitorServers])
        let item = try XCTUnwrap(items.first)
        XCTAssertFalse(target.exists(target.locations.monitorRoot.appendingPathComponent("servers.json")))
        try engine.activateParkedItem(item)
        XCTAssertTrue(target.exists(target.locations.monitorRoot.appendingPathComponent("servers.json")))
        XCTAssertFalse(target.exists(item.parkedURL))
        XCTAssertTrue(engine.parkedRestoredItems().isEmpty)
    }
}
