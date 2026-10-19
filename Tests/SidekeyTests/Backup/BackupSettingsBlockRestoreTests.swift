import XCTest
@testable import Sidekey

@MainActor
final class BackupSettingsBlockRestoreTests: XCTestCase {
    func testAProviderKeyBlockIsIndependentOfAllOrdinarySettings() async throws {
        var target = try ArtifactBackupTestProfile(); defer { target.tearDown() }
        let key = ConfigBackupArchive.makeKey(), account = "byok.soniox.api_key"
        target.addCredential(account, "synthetic-current-key")
        target.defaults.set("deepgram", forKey: "sidekey.models.byokProvider")
        let snapshot = ConfigBackupSnapshot(reason: "Previous version", preferences: ["sidekey.models.byokProvider": .string("soniox")], credentials: [account: "synthetic-saved-key"])
        let (archive, group) = try BackupSettingsBlockRestore.archive(snapshot, section: .credentials, key: key, directory: target.root)
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: archive, key: key, sections: [group])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(try target.credentialStores[account]?.read(), "synthetic-saved-key")
        XCTAssertEqual(target.defaults.string(forKey: "sidekey.models.byokProvider"), "deepgram")
    }

    func testSourceDefaultResetOnlyClearsItsOwnAllowlistedKeysAndPreservesLaterEdits() async throws {
        let target = try ArtifactBackupTestProfile(); defer { target.tearDown() }
        let key = ConfigBackupArchive.makeKey()
        target.defaults.set("soniox", forKey: "sidekey.models.byokProvider")
        target.defaults.set(false, forKey: "sidekey.preferences.brightnessKeys")
        let (archive, group) = try BackupSettingsBlockRestore.archive(ConfigBackupSnapshot(reason: "Defaults", preferences: [:]), section: .models, key: key, directory: target.root)
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: archive, key: key, sections: [group])
        // A different block can still be edited before the normal relaunch.
        target.defaults.set(true, forKey: "sidekey.preferences.brightnessKeys")
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertNil(target.defaults.object(forKey: "sidekey.models.byokProvider"))
        XCTAssertEqual(target.defaults.object(forKey: "sidekey.preferences.brightnessKeys") as? Bool, true)
        XCTAssertNotNil(ArtifactBackupEngine.recoveryCheckpoint(locations: target.locations))
    }
}
