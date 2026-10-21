import CryptoKit
import XCTest
@testable import Sidekey

/// Restore safety: the previous data survives every failure, an interrupted
/// apply is rolled back on the next launch, and only recognised paths are
/// ever written.
@MainActor
final class ArtifactBackupRestoreTests: XCTestCase {
    private var profiles: [ArtifactBackupTestProfile] = []
    private var openMeetingStores: [MeetingsStore] = []

    override func tearDown() async throws {
        for store in openMeetingStores { await store.close() }
        openMeetingStores.removeAll()
        profiles.forEach { $0.tearDown() }
        profiles.removeAll()
    }

    /// A small archive with meetings and the agent workspace, optionally Costs.
    private func makeArchive(withCosts: Bool = false) async throws -> (URL, Data) {
        var profile = try ArtifactBackupTestProfile()
        profiles.append(profile)
        profile.defaults.set("deepgram", forKey: "sidekey.models.byokProvider")
        let meetings = try MeetingsStore(rootDirectory: profile.locations.meetingsCatalog)
        openMeetingStores.append(meetings)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await meetings.insert(
            meta: MeetingMetaWithLocalState(id: UUID(), startedAt: now, endedAt: now, durationSeconds: 1,
                                            title: "Archived", syncStatus: .new, serverVersion: 1,
                                            createdAt: now),
            markdown: "# Archived meeting")
        try profile.write("# Archived memory", to: profile.locations.agentMemory)
        let key = ArtifactBackupTestKeys.make()
        let url = profile.root.appendingPathComponent("archive.exodiabackup")
        var environment = profile.environment(meetings: meetings)
        if withCosts {
            let usage = AIUsageStore(url: profile.locations.usageDatabase)
            try await usage.insert(AIUsageEvent(context: .init(feature: .agent, account: .openRouter, model: "synthetic/model"),
                                                currency: .usd, amount: 0.01, basis: .reported))
            environment.usage = usage
        }
        _ = try await ArtifactBackupEngine(environment: environment).createArchive(at: url, key: key)
        return (url, key)
    }

    /// A target that already holds the user's own data.
    private func makePopulatedTarget() throws -> ArtifactBackupTestProfile {
        var profile = try ArtifactBackupTestProfile()
        profiles.append(profile)
        try profile.write("# My own memory", to: profile.locations.agentMemory)
        try profile.write("my own note", to: profile.locations.meetingsCatalog
            .appendingPathComponent("local-note.md"))
        try profile.write("my own asset", to: profile.locations.historyAssets
            .appendingPathComponent("local-asset.png"))
        try profile.write("local history db", to: profile.locations.historyDatabase)
        return profile
    }

    private var pendingRoot: (ArtifactBackupTestProfile) -> URL { { $0.locations.pendingRestoreRoot } }

    func testFailureAtCommitRollsBackAndKeepsPreviousData() async throws {
        let (archive, key) = try await makeArchive()
        let target = try makePopulatedTarget()
        let arming = target.environment()
        try await ArtifactBackupEngine(environment: arming).stageRestore(
            from: archive, key: key, sections: [.meetings, .workspace])

        var faults = ArtifactBackupFaults()
        faults.beforeCommit = { throw ArtifactBackupError.writeFailed }
        let applying = target.environment(faults: faults)
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: applying))

        XCTAssertEqual(target.contents(of: target.locations.agentMemory), "# My own memory")
        XCTAssertEqual(target.contents(of: target.locations.meetingsCatalog
            .appendingPathComponent("local-note.md")), "my own note")
        XCTAssertEqual(target.contents(of: target.locations.historyDatabase), "local history db")
        XCTAssertEqual(target.contents(of: target.locations.historyAssets
            .appendingPathComponent("local-asset.png")), "my own asset")
        XCTAssertNil(target.defaults.string(forKey: "sidekey.models.byokProvider"))

        let outcome = ArtifactBackupEngine.lastRestoreOutcome(locations: target.locations)
        XCTAssertEqual(outcome?.state, .failed)
        XCTAssertFalse(target.exists(pendingRoot(target).appendingPathComponent("plan.json")))
        XCTAssertFalse(target.exists(pendingRoot(target).appendingPathComponent("journal.json")))
        XCTAssertFalse(target.exists(pendingRoot(target).appendingPathComponent("previous")))
        XCTAssertNil(target.pendingKeyStore.value)
    }

    func testFailureWhileWritingFilesRollsBackEveryTarget() async throws {
        let (archive, key) = try await makeArchive()
        let target = try makePopulatedTarget()
        try await ArtifactBackupEngine(environment: target.environment()).stageRestore(
            from: archive, key: key, sections: [.meetings, .workspace])

        var faults = ArtifactBackupFaults()
        faults.beforeFileEntry = { path in
            if path == "workspace/agent/AGENTS.md" { throw ArtifactBackupError.writeFailed }
        }
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(
            environment: target.environment(faults: faults)))

        XCTAssertEqual(target.contents(of: target.locations.agentMemory), "# My own memory")
        XCTAssertEqual(target.contents(of: target.locations.meetingsCatalog
            .appendingPathComponent("local-note.md")), "my own note")
        XCTAssertFalse(target.exists(target.locations.meetingsCatalog
            .appendingPathComponent("meetings.sqlite")))
    }

    func testInterruptedApplyIsRolledBackOnTheNextLaunch() async throws {
        let (archive, key) = try await makeArchive()
        let target = try makePopulatedTarget()
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(
            from: archive, key: key, sections: [.workspace])

        // Simulate a crash in the middle of an apply: the memory file is moved
        // aside and the journal records it, exactly as the apply path does.
        let root = pendingRoot(target)
        let backup = root.appendingPathComponent("previous", isDirectory: true)
            .appendingPathComponent("0-AGENTS.md")
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: target.locations.agentMemory, to: backup)
        try target.write("half restored", to: target.locations.agentMemory)
        // A journal only counts when it belongs to this transaction.
        let plan = try JSONDecoder.artifactBackup.decode(
            ArtifactRestorePlan.self, from: Data(contentsOf: root.appendingPathComponent("plan.json")))
        let journal = """
        {"id":"\(plan.id.uuidString)","startedAt":"2026-10-19T12:00:00Z","steps":[\
        {"backup":"\(backup.path)","movedAside":true,"target":"\(target.locations.agentMemory.path)"}]}
        """
        try target.write(journal, to: root.appendingPathComponent("journal.json"))

        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: environment)) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .restoreInterrupted)
        }
        XCTAssertEqual(target.contents(of: target.locations.agentMemory), "# My own memory")
        XCTAssertEqual(ArtifactBackupEngine.lastRestoreOutcome(locations: target.locations)?.state,
                       .rolledBack)
        XCTAssertFalse(target.exists(root.appendingPathComponent("journal.json")))
        XCTAssertFalse(target.exists(root.appendingPathComponent("plan.json")))
        // A normal next launch starts without a pending restore.
        XCTAssertNil(try ArtifactBackupEngine.applyPendingRestore(environment: environment))
    }

    func testArmingRefusesWhileAnUnfinishedApplyOwnsThePreviousData() async throws {
        let (archive, key) = try await makeArchive()
        let target = try makePopulatedTarget()
        let root = pendingRoot(target)
        try target.write(#"{"id":"\#(UUID().uuidString)","startedAt":"2026-10-19T12:00:00Z","steps":[]}"#,
                         to: root.appendingPathComponent("journal.json"))
        // Arming must refuse while an apply journal exists, whatever it says.
        do {
            try await ArtifactBackupEngine(environment: target.environment())
                .stageRestore(from: archive, key: key, sections: [.workspace])
            XCTFail("expected restoreInterrupted")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError, .restoreInterrupted)
        }
    }

    func testRepeatedRetriesKeepAPlannedRestoreUntilExplicitCancellation() async throws {
        let (archive, key) = try await makeArchive()
        let target = try makePopulatedTarget()
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(
            from: archive, key: key, sections: [.workspace])

        target.pendingKeyStore.failOnRead = true
        for attempt in 1...5 {
            XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: environment)) { error in
                XCTAssertEqual(error as? ArtifactBackupError, .keyUnavailable, "attempt \(attempt)")
            }
            XCTAssertTrue(target.exists(pendingRoot(target).appendingPathComponent("plan.json")),
                          "attempt \(attempt) must keep the transaction")
        }
        XCTAssertTrue(target.exists(pendingRoot(target).appendingPathComponent("pending.exodiabackup")))
        XCTAssertEqual(target.contents(of: target.locations.agentMemory), "# My own memory")
        XCTAssertTrue(try ArtifactBackupEngine(environment: environment).cancelPlannedRestore())
        XCTAssertFalse(target.exists(pendingRoot(target).appendingPathComponent("plan.json")))
    }

    func testOlderArchiveReplacesStaleHistoryWalFilesTogetherWithTheDatabase() async throws {
        let target = try makePopulatedTarget()
        let key = ArtifactBackupTestKeys.make()
        let archive = target.root.appendingPathComponent("legacy.exodiabackup")
        let database = try ArtifactBackupLegacyContent.historyDatabase(
            texts: ["row 0", "row 1", "row 2"], scratch: target.root.appendingPathComponent("scratch"))
        _ = try ArtifactBackupTestArchive.make(at: archive, key: key, entries: [
            (path: "history/db/history.sqlite", section: .history, data: database)
        ])
        let wal = target.locations.historyDatabase.deletingLastPathComponent()
            .appendingPathComponent("history.sqlite-wal")
        let shm = target.locations.historyDatabase.deletingLastPathComponent()
            .appendingPathComponent("history.sqlite-shm")
        try target.write("stale wal", to: wal)
        try target.write("stale shm", to: shm)

        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(
            from: archive, key: key, sections: [.history])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)

        XCTAssertFalse(target.exists(wal))
        XCTAssertFalse(target.exists(shm))
        let restored = try SQLiteHistoryStore(path: target.locations.historyDatabase.path)
        XCTAssertEqual(try restored.latestClipboardEntries(limit: 20).count, 3)
    }

    /// New archives carry no meeting audio and no history database. Restoring
    /// one keeps what this Mac has there instead of replacing it with nothing.
    func testNewArchiveLeavesThisMacsHistoryAndRecordingsAlone() async throws {
        let (archive, key) = try await makeArchive(withCosts: true)
        let target = try makePopulatedTarget()
        let wal = target.locations.historyDatabase.deletingLastPathComponent()
            .appendingPathComponent("history.sqlite-wal")
        try target.write("local wal", to: wal)
        let recording = target.locations.meetingsStaging
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("chunk-000.wav")
        try target.write("local audio", to: recording)

        let environment = target.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        let preview = try await engine.inspectArchive(at: archive, key: key)
        XCTAssertTrue(preview.summary.sections.isSuperset(of: [.meetings, .history, .workspace]))
        try await engine.stageRestore(from: archive, key: key, sections: preview.summary.sections)
        XCTAssertEqual(try ArtifactBackupEngine.applyPendingRestore(environment: environment)?.state, .applied)

        XCTAssertEqual(target.contents(of: target.locations.agentMemory), "# Archived memory")
        XCTAssertEqual(target.contents(of: target.locations.historyDatabase), "local history db")
        XCTAssertEqual(target.contents(of: wal), "local wal")
        XCTAssertEqual(target.contents(of: target.locations.historyAssets
            .appendingPathComponent("local-asset.png")), "my own asset")
        XCTAssertEqual(target.contents(of: recording), "local audio")
    }

    func testDestinationMappingAcceptsOnlyRecognisedPaths() throws {
        let locations = ArtifactBackupLocations.isolated(root: URL(fileURLWithPath: "/tmp/exodia-map"))
        let meeting = UUID().uuidString
        XCTAssertEqual(try ArtifactRestoreDestination.resolve("settings/preferences.json", in: locations),
                       .inline(.settings))
        XCTAssertEqual(try ArtifactRestoreDestination.resolve("case/vault.key", in: locations),
                       .inline(.caseKey))
        XCTAssertEqual(try ArtifactRestoreDestination.resolve("workspace/notify/sources/demo.json",
                                                             in: locations),
                       .inline(.notifySource("demo.json")))
        XCTAssertEqual(try ArtifactRestoreDestination.resolve("meetings/notes/\(meeting).md", in: locations),
                       .file(locations.meetingsCatalog.appendingPathComponent("\(meeting).md")))
        // Monitor server configuration is parked under a name the runtime does
        // not read, so nothing reconnects by itself.
        XCTAssertEqual(try ArtifactRestoreDestination.resolve("workspace/monitor/servers.json",
                                                              in: locations),
                       .file(locations.monitorRoot.appendingPathComponent("servers.json.restored-inactive")))
        XCTAssertEqual(try ArtifactRestoreDestination.resolve("workspace/monitor/SERVERS.JSON", in: locations),
                       .file(locations.monitorRoot.appendingPathComponent("servers.json.restored-inactive")))
        XCTAssertEqual(try ArtifactRestoreDestination.resolve("workspace/notify/SOURCES/demo.JSON", in: locations),
                       .inline(.notifySource("demo.JSON")))

        for path in ["meetings/notes/not-a-uuid.md", "meetings/db/other.sqlite",
                     "meetings/staged/not-a-uuid/chunk-000.wav",
                     "meetings/staged/\(meeting)/soniox-transcription.json",
                     "history/assets/evil.sh", "workspace/agent/CLAUDE.md",
                     "workspace/unknown/file.json",
                     "case/vault.other"] {
            XCTAssertThrowsError(try ArtifactRestoreDestination.resolve(path, in: locations), path)
        }
        XCTAssertEqual(try ArtifactRestoreDestination.resolve("workspace/notify/sources/demo.json.restored-invalid", in: locations),
                       .file(locations.notifyRoot.appendingPathComponent("sources/demo.json.restored-invalid")))
    }
}
