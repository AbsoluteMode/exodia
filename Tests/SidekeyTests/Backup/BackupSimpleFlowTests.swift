import XCTest
@testable import Sidekey

@MainActor
final class BackupSimpleFlowTests: XCTestCase {
    private var profiles: [ArtifactBackupTestProfile] = []
    private var session: URLSession!
    private var remote: BackupGitHubFixture!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        remote = BackupGitHubFixture(json: { try! JSONSerialization.data(withJSONObject: $0) })
        StubURLProtocol.handler = { [remote] request in try remote!.handle(request) }
    }

    override func tearDown() {
        session.invalidateAndCancel(); StubURLProtocol.reset()
        profiles.forEach { $0.tearDown() }; profiles.removeAll()
        super.tearDown()
    }

    private func profile() throws -> ArtifactBackupTestProfile {
        var profile = try ArtifactBackupTestProfile()
        profile.addCredential("byok.soniox.api_key", nil)
        profiles.append(profile)
        return profile
    }

    private func model(_ profile: ArtifactBackupTestProfile,
                       beforeCreate: @escaping @MainActor () async -> Void = {}) -> BackupViewModel {
        let environment = profile.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        return BackupViewModel(defaults: profile.defaults, keyStore: MemoryTokenStore(), githubTokenStore: MemoryTokenStore(),
            local: BackupLocalStore(root: profile.root.appendingPathComponent("archives")),
            settingsFiles: ConfigBackupFiles(root: profile.root.appendingPathComponent("settings-history")),
            engine: BackupEngineActions(create: { file, key in
                await beforeCreate()
                return try await engine.createArchive(at: file, key: key)
            },
                inspect: { try await engine.inspectArchive(at: $0, key: $1) },
                stage: { try await engine.stageRestore(from: $0, key: $1, sections: $2) }),
            changeProbe: { "synthetic" }, idle: { true }, providerStore: environment.credentialStore,
            previousRestoreOutcome: { nil }, archivedKeyStore: { _ in MemoryTokenStore() },
            pendingKeyStore: MemoryTokenStore(), githubSession: session)
    }

    func testConnectChecksGitHubWithoutCreatingABackupOrRequestingACode() async throws {
        let model = model(try profile())
        XCTAssertFalse(model.canUseGitHubBackup)
        await model.connectGitHub(token: "synthetic-token")
        XCTAssertTrue(model.canUseGitHubBackup)
        XCTAssertEqual(model.githubConnectionState, .connected)
        XCTAssertNil(model.lastBackupAt)
        XCTAssertTrue(model.recoveryCode.isEmpty)
        XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(StubURLProtocol.capturedRequests.allSatisfy { $0.httpMethod == "GET" })
        model.disconnectGitHub()
        XCTAssertFalse(model.canUseGitHubBackup)
        XCTAssertEqual(model.githubConnectionState, .disconnected)
    }

    func testCheckerRejectsRevokedAccessAndDoesNotCreateRepositories() async throws {
        let model = model(try profile())
        await model.connectGitHub(token: "synthetic-token")
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (401, [:], Data()) }
        await model.checkGitHubConnection()
        XCTAssertFalse(model.canUseGitHubBackup)
        XCTAssertEqual(model.githubConnectionState, .needsAttention)
        XCTAssertNotNil(model.githubConnectionError)
        XCTAssertTrue(StubURLProtocol.capturedRequests.allSatisfy { $0.httpMethod == "GET" })
        await model.backupEverything()
        XCTAssertNil(model.lastBackupAt)
    }

    func testOneActionBacksUpAllDataAndCodeRestoresOnACleanMacWithoutConfirmation() async throws {
        let source = try profile(), target = try profile()
        source.defaults.set("fast", forKey: "sidekey.preferences.transcriptionMode")
        try source.credentialStores["byok.soniox.api_key"]!.save("synthetic-provider-key")
        let backup = model(source)
        await backup.connectGitHub(token: "synthetic-token")
        await backup.backupEverything()
        XCTAssertNil(backup.errorMessage)
        XCTAssertNotNil(backup.lastRemoteBackupAt)
        XCTAssertFalse(backup.recoveryCode.isEmpty)
        XCTAssertEqual(remote.publishCount, 1)
        XCTAssertFalse(backup.isEnabled, "A manual action must not silently enable a schedule")
        let code = backup.recoveryCode
        let restore = model(target)
        await restore.connectGitHub(token: "synthetic-token")
        await restore.restoreEverything(code: code)
        XCTAssertNil(restore.errorMessage)
        XCTAssertTrue(restore.needsRestart)
        XCTAssertNil(restore.restorePreview, "The user does not have to choose groups or confirm a preview")
        XCTAssertNil(target.defaults.string(forKey: "sidekey.preferences.transcriptionMode"), "Do not apply over open stores")
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
        XCTAssertEqual(target.defaults.string(forKey: "sidekey.preferences.transcriptionMode"), "fast")
        XCTAssertEqual(try target.credentialStores["byok.soniox.api_key"]!.read(), "synthetic-provider-key")
    }

    func testLeavingBackupWhileUploadingDoesNotRevealCodeLater() async throws {
        let started = expectation(description: "backup started")
        var resume: CheckedContinuation<Void, Never>?
        let model = model(try profile(), beforeCreate: {
            started.fulfill()
            await withCheckedContinuation { resume = $0 }
        })
        await model.connectGitHub(token: "synthetic-token")
        let operation = Task { await model.backupEverything() }
        await fulfillment(of: [started], timeout: 2)
        model.hideRecoveryCode()
        resume?.resume()
        await operation.value
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.lastRemoteBackupAt)
        XCTAssertTrue(model.recoveryCode.isEmpty)
    }

    func testWrongCodeAndMissingBackupNeverStageARestore() async throws {
        let model = model(try profile())
        await model.connectGitHub(token: "synthetic-token")
        await model.restoreEverything(code: "wrong")
        XCTAssertNotNil(model.errorMessage); XCTAssertFalse(model.needsRestart)
        await model.restoreEverything(code: try ConfigBackupArchive.recoveryCode(for: ConfigBackupArchive.makeKey()))
        XCTAssertEqual(model.errorMessage, "No backups found in GitHub.")
        XCTAssertFalse(model.needsRestart)
    }

    func testFailedUploadNeverReturnsASuccessCodeAndKeepsLocalCopy() async throws {
        let model = model(try profile())
        await model.connectGitHub(token: "synthetic-token")
        remote.corruptReadback = true
        await model.backupEverything()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.recoveryCode.isEmpty)
        XCTAssertNotNil(model.lastBackupAt)
        XCTAssertNil(model.lastRemoteBackupAt)
        XCTAssertEqual(remote.publishCount, 0)
        XCTAssertFalse(model.statusText.hasPrefix("Saving"))
    }
}
