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
                       keyStore: MemoryTokenStore = MemoryTokenStore(),
                       githubTokenStore: MemoryTokenStore = MemoryTokenStore(),
                       now: @escaping @MainActor () -> Date = { Date() },
                       changeProbe: @escaping @Sendable () -> String = { "synthetic" },
                       idle: @escaping @MainActor () -> Bool = { true },
                       beforeCreate: @escaping @MainActor () async -> Void = {}) -> BackupViewModel {
        let environment = profile.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        return BackupViewModel(defaults: profile.defaults, keyStore: keyStore, githubTokenStore: githubTokenStore,
            local: BackupLocalStore(root: profile.root.appendingPathComponent("archives")),
            settingsFiles: ConfigBackupFiles(root: profile.root.appendingPathComponent("settings-history")),
            engine: BackupEngineActions(create: { file, key in
                await beforeCreate()
                return try await engine.createArchive(at: file, key: key)
            },
                inspect: { try await engine.inspectArchive(at: $0, key: $1) },
                stage: { try await engine.stageRestore(from: $0, key: $1, sections: $2) }),
            changeProbe: changeProbe, idle: idle, providerStore: environment.credentialStore,
            previousRestoreOutcome: { nil }, archivedKeyStore: { _ in MemoryTokenStore() },
            pendingKeyStore: MemoryTokenStore(), githubSession: session, now: now)
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
        XCTAssertTrue(backup.isEnabled, "Creating the GitHub backup enables subsequent sync")
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

    func testCreatedBackupSyncsSettingsAndRetriesOfflineChangesWithoutRevealingCode() async throws {
        let source = try profile()
        var time = Date()
        var idle = true
        let model = model(source, now: { time }, idle: { idle })
        await model.connectGitHub(token: "synthetic-token")
        await model.poll() // Capture the initial settings history before creation.
        await model.backupEverything()
        XCTAssertEqual(model.syncState, .synced)
        XCTAssertEqual(model.githubBackupURL?.absoluteString, "https://github.com/developer/Exodia-Backup/releases")
        let code = model.recoveryCode
        model.hideRecoveryCode()
        source.defaults.set("fast", forKey: "sidekey.preferences.transcriptionMode")
        await model.poll()
        XCTAssertEqual(model.syncState, .waiting, "The cooldown must not show a stale green check")
        XCTAssertEqual(remote.publishCount, 1)
        time.addTimeInterval(121)
        idle = false
        await model.poll()
        XCTAssertEqual(remote.publishCount, 1, "Active work defers sync")
        idle = true
        remote.corruptReadback = true
        await model.poll()
        XCTAssertEqual(model.syncState, .needsAttention)
        XCTAssertTrue(model.isEnabled, "Offline failures remain retryable")
        XCTAssertEqual(remote.publishCount, 1)
        remote.corruptReadback = false
        time.addTimeInterval(121)
        await model.poll()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.syncState, .synced)
        XCTAssertEqual(remote.publishCount, 2)
        XCTAssertTrue(model.recoveryCode.isEmpty, "Background sync never reveals the credential")
        let target = try profile()
        let restore = self.model(target)
        await restore.connectGitHub(token: "synthetic-token")
        await restore.restoreEverything(code: code)
        XCTAssertNil(restore.errorMessage)
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
        XCTAssertEqual(target.defaults.string(forKey: "sidekey.preferences.transcriptionMode"), "fast")
    }

    func testExistingManualGitHubBackupAdoptsSyncOnceAndKeepsLaterPause() async throws {
        let source = try profile()
        let key = MemoryTokenStore(), token = MemoryTokenStore()
        let first = model(source, keyStore: key, githubTokenStore: token)
        await first.connectGitHub(token: "synthetic-token")
        await first.backupEverything()
        await first.stopAndWait()
        source.defaults.set(false, forKey: "backup.enabled.v1")
        source.defaults.removeObject(forKey: "backup.github-auto-sync.v1") // Previous manual-only release.
        let next = model(source, keyStore: key, githubTokenStore: token)
        await next.start()?.value
        XCTAssertTrue(next.isEnabled)
        XCTAssertTrue(source.defaults.bool(forKey: "backup.github-auto-sync.v1"))
        next.setEnabled(false)
        await next.stopAndWait()
        let paused = model(source, keyStore: key, githubTokenStore: token)
        await paused.start()?.value
        XCTAssertFalse(paused.isEnabled, "A later explicit pause must survive restart")
        await paused.stopAndWait()
    }

    func testCancellingSyncKeepsItPausedWithoutRevealingTheCode() async throws {
        let source = try profile()
        var pause = false
        var resume: CheckedContinuation<Void, Never>?
        let started = expectation(description: "sync started")
        let model = model(source, beforeCreate: {
            if pause {
                started.fulfill()
                await withCheckedContinuation { resume = $0 }
            }
        })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        model.hideRecoveryCode()
        pause = true
        let operation = Task { await model.backupEverything() }
        await fulfillment(of: [started], timeout: 2)
        model.cancelCurrentOperation()
        resume?.resume()
        await operation.value
        XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(source.defaults.bool(forKey: "backup.github-auto-sync.v1"))
        XCTAssertTrue(model.recoveryCode.isEmpty)
        XCTAssertEqual(model.syncState, .paused)
        XCTAssertEqual(remote.publishCount, 1)
    }

    func testArtifactChangesDuringUploadRemainPending() async throws {
        let source = try profile()
        let model = model(source, changeProbe: {
            FileManager.default.fileExists(atPath: source.root.appendingPathComponent("changed").path) ? "after" : "before"
        }, beforeCreate: {
            try! source.write("changed", to: source.root.appendingPathComponent("changed"))
        })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.syncState, .waiting)
        XCTAssertTrue(model.isEnabled)
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

    func testStoppedModelRejectsLateChecksAfterSessionInvalidation() async throws {
        let model = model(try profile())
        await model.connectGitHub(token: "synthetic-token")
        await model.stopAndWait()
        let count = StubURLProtocol.capturedRequests.count
        session.invalidateAndCancel()
        // Reproduces the render teardown ordering that used to abort XCTest
        // with NSGenericException, often during a later unrelated test suite.
        await model.checkGitHubConnection()
        await model.connectGitHub(token: "synthetic-token")
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, count)
        XCTAssertFalse(model.isBusy)
    }

    func testCancelledViewCheckDoesNotStartAnotherRequest() async throws {
        let model = model(try profile())
        await model.connectGitHub(token: "synthetic-token")
        let count = StubURLProtocol.capturedRequests.count
        let check = Task { await model.checkGitHubConnection() }
        check.cancel()
        await check.value
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, count)
        await model.stopAndWait()
    }

    func testCancellingAnInFlightViewCheckCancelsItsRetainedRequest() async throws {
        session.invalidateAndCancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingGitHubCheckProtocol.self]
        session = URLSession(configuration: configuration)
        let model = model(try profile())
        await model.connectGitHub(token: "synthetic-token")
        XCTAssertTrue(model.canUseGitHubBackup)
        let started = expectation(description: "HTTP check is pending")
        let finished = expectation(description: "view task cancelled its retained request")
        PendingGitHubCheckProtocol.onPendingCheck = { started.fulfill() }
        defer { PendingGitHubCheckProtocol.onPendingCheck = nil }
        let check = Task {
            await model.checkGitHubConnection()
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        check.cancel()
        await fulfillment(of: [finished], timeout: 2)
        await model.stopAndWait()
        await check.value
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.githubConnectionState, .connected, "Leaving a view must not turn a valid connection into an auth error")
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
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.syncState, .needsAttention)
        XCTAssertFalse(model.statusText.hasPrefix("Saving"))
    }
}

/// A request that stays in flight until URLSession receives task cancellation.
private final class PendingGitHubCheckProtocol: URLProtocol {
    static var onPendingCheck: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path.hasSuffix("/Exodia-Backup"), let onPendingCheck = Self.onPendingCheck {
            onPendingCheck()
            return
        }
        let object: Any
        if path == "/user" { object = ["login": "developer"] }
        else if path.hasSuffix("/Exodia-Backup") { object = ["name": "Exodia-Backup", "private": true] }
        else { object = [] as [String] }
        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
