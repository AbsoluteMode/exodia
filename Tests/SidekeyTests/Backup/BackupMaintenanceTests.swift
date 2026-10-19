import XCTest
@testable import Sidekey

@MainActor
final class BackupMaintenanceTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var local: BackupLocalStore!
    private var settings: ConfigBackupFiles!
    private var current: MemoryTokenStore!
    private var pending: MemoryTokenStore!
    private var archived: [String: MemoryTokenStore] = [:]
    private var oldKey: Data!
    private var folder: URL!
    private var createFails = false

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = root.appendingPathComponent("destination")
        try ConfigBackupFiles.ensurePrivateDirectory(folder)
        suite = "BackupMaintenanceTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(try folder.bookmarkData(), forKey: "backup.folder-bookmark.v1")
        defaults.set("folder", forKey: "backup.destination-kind.v1")
        defaults.set("isolated-folder", forKey: "backup.destination-id.v1")
        defaults.set("Folder · Synthetic", forKey: "backup.destination-name.v1")
        defaults.set(true, forKey: "backup.recovery-verified.v1")
        defaults.set(true, forKey: "backup.enabled.v1")
        local = BackupLocalStore(root: root.appendingPathComponent("local"))
        settings = ConfigBackupFiles(root: root.appendingPathComponent("settings"))
        oldKey = ConfigBackupArchive.makeKey()
        current = MemoryTokenStore(oldKey.base64EncodedString()); pending = MemoryTokenStore()
        archived = [:]; createFails = false
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() -> BackupViewModel {
        let engine = BackupEngineActions(create: { file, key in
            if self.createFails { throw ConfigBackupError.saveFailed }
            let manifest = try ArtifactBackupTestArchive.make(at: file, key: key,
                entries: [("settings/preferences.json", .settings, try ArtifactBackupTestArchive.settingsPayload())])
            return ArtifactBackupSummary(id: manifest.id, createdAt: manifest.createdAt,
                totalBytes: manifest.contentBytes, fileCount: manifest.entries.count, sections: Set(manifest.sections))
        }, inspect: { file, key in
            let reader = try ArtifactArchiveReader(url: file, archiveKey: key)
            defer { reader.close() }
            let manifest = try ArtifactRestoreTransaction.readManifest(reader)
            // Drain and authenticate the complete stream, including its end.
            for entry in manifest.entries { try reader.forward(entry.bytes) { _ in } }
            try reader.verifyEnd()
            return ArtifactBackupPreview(summary: ArtifactBackupSummary(id: manifest.id, createdAt: manifest.createdAt,
                totalBytes: manifest.contentBytes, fileCount: manifest.entries.count, sections: Set(manifest.sections)), warnings: [])
        }, stage: { _, _, _ in XCTFail("Management must not stage a workspace restore") })
        return BackupViewModel(defaults: defaults, keyStore: current, githubTokenStore: MemoryTokenStore(),
            local: local, settingsFiles: settings, engine: engine, changeProbe: { "synthetic" }, idle: { true },
            providerStore: { _ in MemoryTokenStore() }, previousRestoreOutcome: { nil },
            archivedKeyStore: { id in
                if let store = self.archived[id] { return store }
                let store = MemoryTokenStore(); self.archived[id] = store; return store
            }, pendingKeyStore: pending)
    }

    private func seedBackup() async throws -> URL {
        let file = try await local.archiveURL()
        let manifest = try ArtifactBackupTestArchive.make(at: file, key: oldKey,
            entries: [("settings/preferences.json", .settings, try ArtifactBackupTestArchive.settingsPayload())])
        let summary = ArtifactBackupSummary(id: manifest.id, createdAt: manifest.createdAt,
            totalBytes: manifest.contentBytes, fileCount: manifest.entries.count, sections: Set(manifest.sections))
        let stored = try await local.record(summary, from: file)
        try BackupLocalStore.copyArchive(stored, to: folder.appendingPathComponent(stored.lastPathComponent))
        return stored
    }

    func testReplacingCodeKeepsNewIndependentArchiveAndLocalSettingsHistory() async throws {
        let oldFile = try await seedBackup()
        let snapshot = ConfigBackupSnapshot(reason: "Synthetic history", preferences: [:])
        _ = try await settings.save(ConfigBackupArchive.seal(snapshot, key: oldKey), id: snapshot.id)
        let model = makeModel(); model.recoverySaved = true; model.isEnabled = true
        model.beginReplacingCode()
        let newKey = try ConfigBackupArchive.key(from: model.recoveryCode)
        XCTAssertNotEqual(oldKey, newKey)
        await model.replaceRecoveryCode(verifiedCode: model.recoveryCode)
        XCTAssertNil(model.errorMessage); XCTAssertFalse(model.hasPendingMaintenance)
        XCTAssertTrue(model.isEnabled); XCTAssertTrue(model.recoverySaved)
        XCTAssertEqual(current.value, newKey.base64EncodedString())
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        let versions = try await local.versions()
        XCTAssertEqual(versions.count, 1)
        let saved = try XCTUnwrap(versions.first?.localURL)
        XCTAssertNoThrow(try ArtifactArchiveReader(url: saved, archiveKey: newKey).close())
        XCTAssertThrowsError(try ArtifactRestoreTransaction.readManifest(ArtifactArchiveReader(url: saved, archiveKey: oldKey)))
        let history = try await settings.load(key: oldKey)
        XCTAssertEqual(history, [snapshot])
        XCTAssertEqual(archived[ConfigBackupArchive.keyID(oldKey)]?.value, oldKey.base64EncodedString())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [saved.lastPathComponent])
    }

    func testFailedNewBackupNeverDeletesOldCopiesOrChangesActiveKey() async throws {
        let oldFile = try await seedBackup(); createFails = true
        let model = makeModel(); model.recoverySaved = true; model.isEnabled = true
        model.beginReplacingCode()
        await model.replaceRecoveryCode(verifiedCode: model.recoveryCode)
        XCTAssertTrue(model.hasPendingMaintenance); XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(current.value, oldKey.base64EncodedString())
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(oldFile.lastPathComponent).path))
        XCTAssertNotNil(model.errorMessage)
        model.setEnabled(true); XCTAssertFalse(model.isEnabled)
        createFails = false
        await model.resumeBackupManagement()
        XCTAssertFalse(model.hasPendingMaintenance); XCTAssertTrue(model.isEnabled)
    }

    func testFailedCleanupResumesAfterReconstructionWithoutLosingNewKey() async throws {
        _ = try await seedBackup()
        let external = root.appendingPathComponent("unrelated.txt")
        try Data("synthetic".utf8).write(to: external)
        let unsafe = folder.appendingPathComponent(UUID().uuidString + ".exodiabackup")
        try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: external)
        let first = makeModel(); first.recoverySaved = true; first.isEnabled = true
        first.beginReplacingCode()
        let code = first.recoveryCode
        await first.replaceRecoveryCode(verifiedCode: code)
        XCTAssertTrue(first.hasPendingMaintenance); XCTAssertFalse(first.isEnabled)
        let pendingPlan = try await local.maintenance()
        let plan = try XCTUnwrap(pendingPlan)
        XCTAssertEqual(plan.phase, .cleanup)
        let active = current.value
        let replacement = try XCTUnwrap(plan.replacement)
        let replacementFile = await local.fileURL(replacement.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementFile.path))
        // Simulate a new controller after restart. The durable pending state
        // is loaded by start; set it explicitly here to avoid runtime timers.
        let resumed = makeModel(); resumed.hasPendingMaintenance = true
        try FileManager.default.removeItem(at: unsafe)
        await resumed.resumeBackupManagement()
        XCTAssertNil(resumed.errorMessage); XCTAssertFalse(resumed.hasPendingMaintenance)
        XCTAssertEqual(current.value, active)
        XCTAssertEqual(current.value, try ConfigBackupArchive.key(from: code).base64EncodedString())
        XCTAssertEqual(try String(contentsOf: external), "synthetic")
        let resumedVersions = try await local.versions()
        XCTAssertEqual(resumedVersions.count, 1)
    }

    func testDeleteRemovesFullCopiesRetiresCodeAndKeepsWorkingSettings() async throws {
        _ = try await seedBackup()
        defaults.set("keep", forKey: "sidekey.preferences.language")
        let unrelated = folder.appendingPathComponent("personal-document.txt")
        try Data("keep".utf8).write(to: unrelated)
        let model = makeModel(); model.isEnabled = true; model.recoverySaved = true
        await model.deleteBackups()
        XCTAssertNil(model.errorMessage); XCTAssertFalse(model.hasPendingMaintenance)
        XCTAssertFalse(model.isEnabled); XCTAssertFalse(model.recoverySaved)
        XCTAssertNil(defaults.string(forKey: "backup.destination-kind.v1"))
        XCTAssertNotEqual(current.value, oldKey.base64EncodedString())
        XCTAssertEqual(defaults.string(forKey: "sidekey.preferences.language"), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["personal-document.txt"])
        let remaining = try await local.versions()
        XCTAssertTrue(remaining.isEmpty)
        model.beginSetup()
        XCTAssertNotEqual(try ConfigBackupArchive.key(from: model.recoveryCode), oldKey)
    }

    func testWrongConfirmationAndCancelledNewCodeKeepExistingBackups() async throws {
        let oldFile = try await seedBackup()
        let model = makeModel(); model.recoverySaved = true
        model.beginReplacingCode()
        await model.replaceRecoveryCode(verifiedCode: try ConfigBackupArchive.recoveryCode(for: oldKey))
        XCTAssertNotNil(model.errorMessage); XCTAssertFalse(model.hasPendingMaintenance)
        XCTAssertEqual(current.value, oldKey.base64EncodedString())
        model.cancelReplacingCode()
        XCTAssertTrue(model.recoveryCode.isEmpty); XCTAssertFalse(model.isReplacingCode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
    }

    func testCannotRetireKeyUntilLocalHistoryKeyIsSafelyRetained() async throws {
        let oldFile = try await seedBackup()
        let id = ConfigBackupArchive.keyID(oldKey)
        let failed = MemoryTokenStore(); failed.failOnSave = true
        archived[id] = failed
        defaults.set([id], forKey: "backup.archived-key-ids.v1")
        let model = makeModel(); model.recoverySaved = true; model.isEnabled = true
        await model.deleteBackups()
        XCTAssertNotNil(model.errorMessage); XCTAssertFalse(model.hasPendingMaintenance)
        XCTAssertFalse(model.isEnabled, "A management failure must not continue uploading with an exposed code")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertEqual(current.value, oldKey.base64EncodedString())
    }

    func testDeleteCanEraseDamagedUncataloguedBackupsAndKeepsPauseAfterInterruptedCleanup() async throws {
        let oldFile = try await seedBackup()
        let unrelated = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let unsafe = folder.appendingPathComponent(UUID().uuidString + ".exodiabackup")
        try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: unrelated)
        let model = makeModel(); model.recoverySaved = true; model.isEnabled = true
        await model.deleteBackups()
        XCTAssertTrue(model.hasPendingMaintenance); XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        try FileManager.default.removeItem(at: unsafe)
        let damaged = local.root.appendingPathComponent(UUID().uuidString + ".exodiabackup")
        try Data("damaged".utf8).write(to: damaged)
        try Data("unreadable catalog".utf8).write(to: local.root.appendingPathComponent("catalog.json"))
        await model.resumeBackupManagement()
        XCTAssertFalse(model.hasPendingMaintenance); XCTAssertFalse(model.isEnabled)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: damaged.path))
        XCTAssertEqual(try String(contentsOf: unrelated), "keep")
    }

    func testStartupBlocksOrdinaryActionsBeforeLoadingPendingRequest() async throws {
        let oldFile = try await seedBackup()
        let newKey = ConfigBackupArchive.makeKey()
        try pending.save(newKey.base64EncodedString())
        try await local.saveMaintenance(.init(kind: .deleteBackups, destinationID: "isolated-folder",
            newKeyID: ConfigBackupArchive.keyID(newKey), resumeAutomatic: true))
        let model = makeModel()
        model.start()
        defer { model.stop() }
        XCTAssertTrue(model.isBusy)
        await model.backupNow()
        for _ in 0..<100 where model.isBusy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(model.hasPendingMaintenance); XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(model.localSettingsVersions.isEmpty, "Local settings history continues while cloud management is paused")
        await model.restoreSettingsDefaults(.models)
        XCTAssertFalse(model.needsRestart)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        let records = try await local.records()
        XCTAssertEqual(records.count, 1)
    }

    func testActiveKeySaveFailureKeepsPublishedReplacementAndResumesCleanup() async throws {
        let oldFile = try await seedBackup()
        let model = makeModel(); model.recoverySaved = true; model.isEnabled = true
        model.beginReplacingCode()
        let code = model.recoveryCode
        current.failOnSave = true
        await model.replaceRecoveryCode(verifiedCode: code)
        XCTAssertTrue(model.hasPendingMaintenance); XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(current.value, oldKey.base64EncodedString())
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        let plan = try await local.maintenance()
        XCTAssertEqual(plan?.phase, .cleanup)
        let replacement = try XCTUnwrap(plan?.replacement)
        let folderCopy = folder.appendingPathComponent(replacement.id.uuidString.lowercased() + ".exodiabackup")
        try Data("damaged after the first verified upload".utf8).write(to: folderCopy)
        current.failOnSave = false
        await model.resumeBackupManagement()
        XCTAssertNil(model.errorMessage); XCTAssertFalse(model.hasPendingMaintenance)
        XCTAssertEqual(current.value, try ConfigBackupArchive.key(from: code).base64EncodedString())
        let localCopy = await local.fileURL(replacement.id)
        XCTAssertEqual(try Data(contentsOf: folderCopy), try Data(contentsOf: localCopy))
    }
}
