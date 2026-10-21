import XCTest
@testable import Sidekey

/// Scenarios from the 2026-10-21 automatic backup loop: a Notify script's
/// status file changed every few seconds, every change produced another
/// complete local snapshot and the Mac ran out of disk.
/// WHY: .project-docs/decisions/2026-10-21-backup-capture-pacing.md
@MainActor
final class BackupCapturePacingTests: XCTestCase {
    private var profiles: [ArtifactBackupTestProfile] = []
    private var session: URLSession!
    private var remote: BackupGitHubFixture!
    private var offline = false

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        remote = BackupGitHubFixture(json: { try! JSONSerialization.data(withJSONObject: $0) })
        offline = false
        StubURLProtocol.handler = { [unowned self] request in
            if self.offline { throw URLError(.notConnectedToInternet) }
            return try self.remote.handle(request)
        }
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
                       now: @escaping @MainActor () -> Date,
                       freeSpace: @escaping @Sendable () -> Int64? = { 500_000_000_000 },
                       beforeCreate: @escaping @MainActor () async -> Void = {}) -> BackupViewModel {
        let environment = profile.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        let locations = profile.locations
        return BackupViewModel(defaults: profile.defaults, keyStore: keyStore, githubTokenStore: githubTokenStore,
            local: BackupLocalStore(root: archives(profile)),
            settingsFiles: ConfigBackupFiles(root: profile.root.appendingPathComponent("settings-history")),
            engine: BackupEngineActions(create: { file, key in
                await beforeCreate()
                return try await engine.createArchive(at: file, key: key)
            },
                inspect: { try await engine.inspectArchive(at: $0, key: $1) },
                stage: { try await engine.stageRestore(from: $0, key: $1, sections: $2) },
                createIfChanged: { file, key, previous in
                    await beforeCreate()
                    return try await engine.createArchiveIfChanged(at: file, key: key, previousFingerprint: previous)
                }),
            changeProbe: { BackupChangeProbe.stamp(locations: locations) },
            idle: { true }, providerStore: environment.credentialStore,
            previousRestoreOutcome: { nil }, archivedKeyStore: { _ in MemoryTokenStore() },
            pendingKeyStore: MemoryTokenStore(), githubSession: session, now: now,
            availableCapacity: { _ in freeSpace() },
            recoveryAuthentication: { true },
            cleanupWork: { try await engine.cleanupAbandonedWork() })
    }

    private func archives(_ profile: ArtifactBackupTestProfile) -> URL { profile.root.appendingPathComponent("archives") }

    private func files(_ profile: ArtifactBackupTestProfile, _ suffix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: archives(profile).path).filter { $0.hasSuffix(suffix) }.sorted()
    }

    /// Like a chat Notify script: a working status file rewritten on every message.
    private func touchStatus(_ profile: ArtifactBackupTestProfile, _ counter: Int) throws {
        try profile.write("{\"messages_received\": \(counter)}",
                          to: profile.locations.notifyRoot.appendingPathComponent("chat-source/status.json"))
    }

    func testSourceChangingEveryMinuteCreatesAtMostOneSnapshotPerHour() async throws {
        let source = try profile()
        var time = Date(), captures = 0
        try touchStatus(source, 0)
        let model = model(source, now: { time }, beforeCreate: { captures += 1 })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        XCTAssertEqual(captures, 1)
        XCTAssertTrue(model.isEnabled)
        for minute in 1...150 {
            try touchStatus(source, minute)
            time.addTimeInterval(60)
            await model.poll()
            if minute == 30 {
                XCTAssertEqual(model.syncState, .waiting, "A detected change is pending, not hidden")
                XCTAssertNotNil(model.nextAutomaticCapture)
            }
        }
        XCTAssertEqual(captures, 3, "150 minutes of constant changes: the first backup plus two hourly captures")
        XCTAssertEqual(remote.publishCount, 3)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try files(source, ".exodiabackup").count, 1, "Only the newest uploaded copy stays on this Mac")
        XCTAssertTrue(try files(source, ".upload").isEmpty)
    }

    func testExplicitBackUpIsNotDelayedByTheHourlySchedule() async throws {
        let source = try profile()
        var time = Date(), captures = 0
        let model = model(source, now: { time }, beforeCreate: { captures += 1 })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        try touchStatus(source, 1)
        time.addTimeInterval(130)
        await model.backupEverything()
        XCTAssertEqual(captures, 2)
        XCTAssertEqual(remote.publishCount, 2)
        XCTAssertNil(model.errorMessage)
    }

    func testAlmostFullDiskSkipsAutomaticCaptureUntilSpaceReturns() async throws {
        let source = try profile()
        var time = Date(), captures = 0
        nonisolated(unsafe) var free: Int64 = 500_000_000_000
        let model = model(source, now: { time }, freeSpace: { free }, beforeCreate: { captures += 1 })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        XCTAssertEqual(captures, 1)
        let before = try files(source, ".exodiabackup")

        free = 3_000_000_000 // Below the automatic reserve.
        try touchStatus(source, 1)
        time.addTimeInterval(3600)
        await model.poll()
        XCTAssertEqual(captures, 1, "No export starts without room for its archive and the reserve")
        XCTAssertEqual(model.syncState, .needsAttention)
        XCTAssertTrue(model.errorMessage?.contains("waiting for disk space") == true, model.errorMessage ?? "")
        XCTAssertEqual(try files(source, ".exodiabackup"), before, "No partial archive is left behind")
        XCTAssertTrue(model.isEnabled, "Low disk space does not silently pause sync")

        free = 1_000_000_000 // Below even an explicit backup's margin.
        await model.backupEverything()
        XCTAssertEqual(captures, 1)
        XCTAssertTrue(model.errorMessage?.contains("not enough disk space") == true, model.errorMessage ?? "")

        free = 500_000_000_000
        time.addTimeInterval(121)
        await model.poll()
        XCTAssertEqual(captures, 2)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(remote.publishCount, 2)
    }

    func testRetentionKeepsTheDeltaParentAndUnsentWorkButNotOlderUploads() async throws {
        let source = try profile()
        var time = Date()
        let model = model(source, now: { time })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        for index in 1...3 {
            try touchStatus(source, index)
            time.addTimeInterval(3600)
            await model.poll()
        }
        XCTAssertEqual(remote.publishCount, 4)
        XCTAssertEqual(try files(source, ".exodiabackup").count, 1)
        let local = BackupLocalStore(root: archives(source))
        let uploaded = try await local.records()
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertEqual(uploaded.first?.uploadedDepth, 3, "Each upload stays a delta against the kept parent")

        offline = true
        for index in 4...5 {
            try touchStatus(source, index)
            time.addTimeInterval(3600)
            await model.poll()
        }
        XCTAssertEqual(try files(source, ".exodiabackup").count, 3,
                       "The delta parent, the resumable prepared transfer and the freshest unsent snapshot")
        XCTAssertEqual(model.syncState, .needsAttention)

        offline = false
        time.addTimeInterval(1_000)
        await model.poll()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(remote.publishCount, 6)
        XCTAssertEqual(try files(source, ".exodiabackup").count, 1)
        let finalDepth = try await local.records().first?.uploadedDepth
        XCTAssertEqual(finalDepth, 5)
    }

    /// A catalog left by the earlier 30-copy policy, after archives were deleted by hand.
    private func legacyCatalog(_ profile: ArtifactBackupTestProfile) throws -> (parent: UUID, restorePoint: UUID) {
        let root = archives(profile)
        try ConfigBackupFiles.ensurePrivateDirectory(root)
        func record(_ age: TimeInterval, copied: Bool, recoveryOnly: Bool = false, file: Bool = true) throws -> BackupLocalStore.Record {
            let summary = ArtifactBackupSummary(id: UUID(), createdAt: Date().addingTimeInterval(-age), totalBytes: 3,
                                                fileCount: 1, sections: [.settings])
            if file { try profile.write("old", to: root.appendingPathComponent(summary.id.uuidString.lowercased() + ".exodiabackup")) }
            return BackupLocalStore.Record(summary: summary, remoteID: copied ? 1 : nil, copiedAt: copied ? Date() : nil,
                                           destinationID: copied ? "github:developer/exodia-backup" : nil,
                                           uploadedDepth: copied ? 0 : nil, recoveryOnly: recoveryOnly, automatic: true)
        }
        let newestCopied = try record(100, copied: true)
        let olderCopied = try (1...4).map { try record(Double(200 + $0), copied: true) }
        let deletedCopy = try record(300, copied: true, file: false)
        let restorePoint = try record(400, copied: false, recoveryOnly: true)
        let deletedPending = try record(50, copied: false, file: false)
        try ConfigBackupFiles.write(JSONEncoder().encode([deletedPending, newestCopied] + olderCopied + [deletedCopy, restorePoint]),
                                    to: root.appendingPathComponent("catalog.json"))
        return (newestCopied.summary.id, restorePoint.summary.id)
    }

    func testRetentionForgetsDeletedArchivesAndReleasesUploadedSurplus() async throws {
        let source = try profile()
        let expected = try legacyCatalog(source)
        let local = BackupLocalStore(root: archives(source))
        let result = try await local.applyRetention(destinationID: "github:developer/exodia-backup")
        XCTAssertEqual(result, .init(forgottenPending: 1, removedCopies: 4))
        let kept = try await local.records().map(\.summary.id)
        XCTAssertEqual(Set(kept), [expected.parent, expected.restorePoint],
                       "The delta parent and a restore checkpoint stay; uploaded surplus and missing entries go")
        XCTAssertEqual(try files(source, ".exodiabackup").count, 2)
        let repeated = try await local.applyRetention(destinationID: "github:developer/exodia-backup")
        XCTAssertEqual(repeated, .init(),
                       "Retention is idempotent")
    }

    func testLaunchAppliesRetentionWhilePaused() async throws {
        let source = try profile()
        let expected = try legacyCatalog(source)
        source.defaults.set("github:developer/exodia-backup", forKey: "backup.destination-id.v1")
        source.defaults.set(false, forKey: "backup.enabled.v1")
        source.defaults.set(true, forKey: "backup.recovery-verified.v1")
        let model = model(source, keyStore: MemoryTokenStore(ConfigBackupArchive.makeKey().base64EncodedString()), now: { Date() })
        await model.start()?.value
        XCTAssertFalse(model.isEnabled)
        let kept = try await BackupLocalStore(root: archives(source)).records().map(\.summary.id)
        XCTAssertEqual(Set(kept),
                       [expected.parent, expected.restorePoint])
        XCTAssertEqual(try files(source, ".exodiabackup").count, 2)
        XCTAssertNil(model.errorMessage)
        await model.stopAndWait()
    }

    func testMissingLocalArchivesDoNotBlockLaterSync() async throws {
        let source = try profile()
        var time = Date()
        let model = model(source, now: { time })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        offline = true
        try touchStatus(source, 1)
        time.addTimeInterval(3600)
        await model.poll()
        XCTAssertEqual(try files(source, ".exodiabackup").count, 2)
        XCTAssertEqual(try files(source, ".upload").count, 1, "An offline snapshot is prepared as a delta")

        // Someone frees disk space by deleting every archive by hand.
        for name in try files(source, ".exodiabackup") {
            try FileManager.default.removeItem(at: archives(source).appendingPathComponent(name))
        }
        offline = false
        time.addTimeInterval(1_000)
        await model.poll()
        XCTAssertNil(model.errorMessage, "Missing archives are forgotten instead of failing every retry")
        XCTAssertTrue(try files(source, ".upload").isEmpty)
        XCTAssertEqual(model.syncState, .waiting)
        XCTAssertEqual(remote.publishCount, 1)

        time.addTimeInterval(3600)
        await model.poll()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(remote.publishCount, 2, "Without a local parent the next copy is a complete upload")
        let depth = try await BackupLocalStore(root: archives(source)).records().first?.uploadedDepth
        XCTAssertEqual(depth, 0)
        XCTAssertEqual(model.syncState, .synced)
    }

    func testPreparedDeltaRemovedBeforeAnyDraftIsPreparedAgain() async throws {
        let source = try profile()
        var time = Date()
        let model = model(source, now: { time })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        offline = true
        try touchStatus(source, 1)
        time.addTimeInterval(3600)
        await model.poll()
        let upload = try XCTUnwrap(try files(source, ".upload").first)
        try FileManager.default.removeItem(at: archives(source).appendingPathComponent(upload))
        offline = false
        time.addTimeInterval(1_000)
        await model.poll()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(remote.publishCount, 2)
        let depth = try await BackupLocalStore(root: archives(source)).records().first?.uploadedDepth
        XCTAssertEqual(depth, 1)
    }

    func testPauseSurvivesRestartAndBackUpDoesNotResumeIt() async throws {
        let source = try profile()
        let key = MemoryTokenStore(), token = MemoryTokenStore()
        var time = Date(), captures = 0
        let first = model(source, keyStore: key, githubTokenStore: token, now: { time }, beforeCreate: { captures += 1 })
        await first.connectGitHub(token: "synthetic-token")
        await first.backupEverything()
        XCTAssertTrue(first.canChangeAutomaticBackup)
        first.setAutomaticBackup(false)
        XCTAssertFalse(first.isEnabled)
        XCTAssertEqual(first.syncState, .paused)
        await first.stopAndWait()

        let next = model(source, keyStore: key, githubTokenStore: token, now: { time }, beforeCreate: { captures += 1 })
        await next.start()?.value
        XCTAssertFalse(next.isEnabled, "Pause survives restart")
        XCTAssertEqual(next.syncState, .paused)
        try touchStatus(source, 1)
        time.addTimeInterval(3600)
        await next.poll()
        XCTAssertEqual(captures, 1, "Paused sync captures nothing")

        await next.backupEverything()
        XCTAssertEqual(captures, 2)
        XCTAssertEqual(remote.publishCount, 2)
        XCTAssertFalse(next.isEnabled, "Back up saves one copy without resuming")
        XCTAssertTrue(next.statusText.contains("stays paused"), next.statusText)

        next.setAutomaticBackup(true)
        XCTAssertTrue(next.isEnabled)
        try touchStatus(source, 2)
        time.addTimeInterval(3600)
        await next.poll()
        XCTAssertEqual(captures, 3)

        // A pause written outside the view (another process) applies at the next poll.
        source.defaults.set(false, forKey: "backup.enabled.v1")
        try touchStatus(source, 3)
        time.addTimeInterval(3600)
        await next.poll()
        XCTAssertFalse(next.isEnabled)
        XCTAssertEqual(captures, 3)
        await next.stopAndWait()
    }

    func testPausingCancelsARunningAutomaticBackup() async throws {
        let source = try profile()
        var time = Date(), hold = false
        var resume: CheckedContinuation<Void, Never>?
        let started = expectation(description: "automatic capture started")
        let model = model(source, now: { time }, beforeCreate: {
            guard hold else { return }
            started.fulfill()
            await withCheckedContinuation { resume = $0 }
        })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        hold = true
        try touchStatus(source, 1)
        time.addTimeInterval(3600)
        let poll = Task { await model.poll() }
        await fulfillment(of: [started], timeout: 2)
        model.setAutomaticBackup(false)
        resume?.resume()
        await poll.value
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.syncState, .paused)
        XCTAssertEqual(remote.publishCount, 1)
    }
}
