import Foundation
import SQLite3
import XCTest
@testable import Sidekey

/// Costs history backup: the live journal is exported through its own writer,
/// every archive copy passes one validator, and a restore keeps spending this
/// Mac recorded before it. Isolated temporary stores only.
final class ArtifactUsageBackupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    private func event(_ id: String, _ amount: Double?, basis: AIUsageBasis? = nil, account: ProviderAccount = .openRouter,
                       feature: AIFeature = .dropSmartCleanup, model: String = "vendor/model",
                       at seconds: TimeInterval = 1_800_000_000, audio: Double = 0) -> AIUsageEvent {
        AIUsageEvent(id: id, createdAt: Date(timeIntervalSince1970: seconds),
                     context: .init(feature: feature, account: account, model: model),
                     currency: account == .elevenLabs ? .elevenLabsCredits : .usd, amount: amount,
                     basis: basis ?? (amount == nil ? .unavailable : .reported), audioSeconds: audio)
    }

    private let everyKind: [AIUsageEvent] = {
        let server = ProviderAccount.server(UUID(uuidString: "6F1C2D3E-4A5B-4C6D-8E9F-0A1B2C3D4E5F")!)
        func make(_ id: String, _ amount: Double?, _ basis: AIUsageBasis, _ account: ProviderAccount,
                  _ feature: AIFeature, _ model: String, _ at: TimeInterval, _ audio: Double) -> AIUsageEvent {
            AIUsageEvent(id: id, createdAt: Date(timeIntervalSince1970: at),
                         context: .init(feature: feature, account: account, model: model),
                         currency: account == .elevenLabs ? .elevenLabsCredits : .usd,
                         amount: amount, basis: basis, audioSeconds: audio)
        }
        return [
            make("soniox:client-ref-1", 0.0021, .estimated, .soniox, .dropFast, "stt-rt-v5", 1_800_000_000, 63),
            make("soniox-job:job-1", 0.0174, .reported, .soniox, .meetings, "stt-async-v5", 1_800_000_100, 626.5),
            make("elevenlabs:req-1", 37.5, .estimated, .elevenLabs, .agentVoice, "scribe_v2_realtime", 1_800_000_200, 12),
            make("elevenlabs:req-2", nil, .unavailable, .elevenLabs, .dropSmart, "scribe_v2_realtime", 1_800_000_300, 4),
            make("opencode:session:part-1", 0.031, .estimated, .anthropic, .agent, "claude-opus-5-5", 1_800_000_400, 0),
            make("opencode-run:run-1", nil, .unavailable, .openAI, .agent, "gpt-model", 1_800_000_500, 0),
            make(UUID().uuidString, 0, .reported, .openRouter, .meetingNotes, "vendor/model:free", 1_800_000_600, 0),
            make(UUID().uuidString, nil, .unavailable, server, .dropSmartCleanup, "my local model", 1_800_000_700, 0)
        ]
    }()

    private func allEvents(_ database: URL) async throws -> [AIUsageEvent] {
        try await AIUsageStore(url: database).events(from: .distantPast, to: .distantFuture)
    }

    private func exec(_ database: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }

    private func digest(_ file: URL) throws -> String { try ArtifactBackupDigest.ofFile(file).digest }

    private func exported(_ store: AIUsageStore, _ name: String,
                          callerFile: StaticString = #filePath, line: UInt = #line) async throws -> URL {
        let file = try await store.exportArtifactGeneration(into: url(name))
        return try XCTUnwrap(file, file: callerFile, line: line)
    }

    // MARK: - Export

    func testExportPreservesEveryRecordedPriceKindAndIsUsableByTheStore() async throws {
        let live = url("live/ai-usage.sqlite"), store = AIUsageStore(url: live)
        for event in everyKind { try await store.insert(event) }
        let snapshot = try await exported(store, "export")
        XCTAssertEqual(snapshot.lastPathComponent, "ai-usage.sqlite")
        XCTAssertEqual(try ArtifactUsageBackup.validate(database: snapshot), everyKind.count)
        let restored = try await allEvents(snapshot)
        XCTAssertEqual(restored.sorted { $0.id < $1.id }, everyKind.sorted { $0.id < $1.id })
        let mode = try FileManager.default.attributesOfItem(atPath: snapshot.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + "-journal"))
        // A later reported price still upgrades an estimate in a restored copy.
        let upgraded = AIUsageEvent(id: "soniox:client-ref-1", createdAt: everyKind[0].createdAt,
                                    context: everyKind[0].context, currency: .usd, amount: 0.002,
                                    basis: .reported, audioSeconds: 63)
        try await AIUsageStore(url: snapshot).insert(upgraded)
        let reread = try await allEvents(snapshot)
        XCTAssertEqual(reread.first { $0.id == upgraded.id }, upgraded)
    }

    func testUnchangedJournalExportsByteIdenticalSnapshotsForContentDeduplication() async throws {
        let store = AIUsageStore(url: url("live/ai-usage.sqlite"))
        for event in everyKind { try await store.insert(event) }
        let first = try await exported(store, "one")
        let second = try await exported(store, "two")
        XCTAssertEqual(try digest(first), try digest(second))
        try await store.insert(event("new", 0.01))
        let third = try await exported(store, "three")
        XCTAssertNotEqual(try digest(first), try digest(third))
    }

    func testMissingJournalExportsNothingAndCreatesNoFile() async throws {
        let live = url("live/ai-usage.sqlite")
        let snapshot = try await AIUsageStore(url: live).exportArtifactGeneration(into: url("export"))
        XCTAssertNil(snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
    }

    func testUnpersistedPendingRowsRefuseAnIncompleteSnapshot() async throws {
        let store = AIUsageStore(url: url("pending/ai-usage.sqlite"))
        await store.record(event("invalid-pending", 0.01, model: ""))
        do {
            _ = try await store.exportArtifactGeneration(into: url("incomplete"))
            XCTFail("A snapshot must not silently omit rows still waiting in memory")
        } catch { XCTAssertTrue(error is AIUsageStoreError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("incomplete/ai-usage.sqlite").path))
    }

    func testMergeIncludesCommittedRowsStillInThePriorWriteAheadLog() async throws {
        let store = AIUsageStore(url: url("wal-source/ai-usage.sqlite"))
        try await store.insert(event("initial", 0.01))
        let prior = try await exported(store, "wal-prior")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(prior.path, &connection, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            INSERT INTO usage_events SELECT 'only-in-wal', created_at, feature, account, model,
                currency, amount, basis, audio_seconds FROM usage_events LIMIT 1;
            """, nil, nil, nil), SQLITE_OK)
        let restored = try await exported(store, "wal-restored")
        let warning = try ArtifactUsageBackup.mergePrior(database: prior, rollbackJournal: nil,
            writeAheadLog: URL(fileURLWithPath: prior.path + "-wal"), into: restored, scratch: url("scratch"))
        XCTAssertNil(warning)
        let events = try await allEvents(restored)
        XCTAssertEqual(Set(events.map(\.id)), ["initial", "only-in-wal"])
    }

    func testExportIsSerializedWithConcurrentWriters() async throws {
        let store = AIUsageStore(url: url("live/ai-usage.sqlite"))
        try await store.insert(event("seed", 0.01))
        let rows = (0..<200).map { event("row-\($0)", Double($0) / 1000) }
        let exports = stride(from: 0, to: 200, by: 50).map { url("export-\($0)") }
        let snapshots = try await withThrowingTaskGroup(of: URL?.self) { group -> [URL] in
            for (index, row) in rows.enumerated() {
                group.addTask { try await store.insert(row); return nil }
                if index % 50 == 0 {
                    let directory = exports[index / 50]
                    group.addTask { try await store.exportArtifactGeneration(into: directory) }
                }
            }
            var result: [URL] = []
            for try await url in group { if let url { result.append(url) } }
            return result
        }
        XCTAssertEqual(snapshots.count, 4)
        for snapshot in snapshots {
            XCTAssertTrue((1...201).contains(try ArtifactUsageBackup.validate(database: snapshot)))
        }
        let final = try await exported(store, "final")
        XCTAssertEqual(try ArtifactUsageBackup.validate(database: final), 201)
    }

    // MARK: - Validation

    private func validJournal(_ name: String) async throws -> URL {
        let database = url("\(name)/ai-usage.sqlite")
        let store = AIUsageStore(url: database)
        for event in everyKind { try await store.insert(event) }
        return database
    }

    private func assertRejected(_ database: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ArtifactUsageBackup.validate(database: database), file: file, line: line) { error in
            XCTAssertNotNil(error as? ArtifactBackupError, file: file, line: line)
        }
    }

    func testValidatorRejectsForeignSchemaObjectsThatCouldRunLater() async throws {
        let trigger = try await validJournal("trigger")
        try exec(trigger, "CREATE TRIGGER t AFTER INSERT ON usage_events BEGIN DELETE FROM usage_events; END;")
        assertRejected(trigger)

        let extraTable = try await validJournal("table")
        try exec(extraTable, "CREATE TABLE notes (body TEXT);")
        assertRejected(extraTable)

        let view = try await validJournal("view")
        try exec(view, "CREATE VIEW everything AS SELECT * FROM usage_events;")
        assertRejected(view)

        let noKey = url("nokey/ai-usage.sqlite")
        try FileManager.default.createDirectory(at: noKey.deletingLastPathComponent(), withIntermediateDirectories: true)
        try exec(noKey, """
            CREATE TABLE usage_events (id TEXT, created_at REAL NOT NULL, feature TEXT NOT NULL,
              account TEXT NOT NULL, model TEXT NOT NULL, currency TEXT NOT NULL,
              amount REAL, basis TEXT NOT NULL, audio_seconds REAL NOT NULL);
            CREATE INDEX usage_date ON usage_events(created_at);
            """)
        assertRejected(noKey)

        let garbage = url("garbage.sqlite")
        try Data(repeating: 0x41, count: 4096).write(to: garbage)
        assertRejected(garbage)
    }

    func testValidatorRejectsRowsTheStoreWouldNeverWrite() async throws {
        let cases = [
            "UPDATE usage_events SET amount = 0.5 WHERE basis = 'unavailable'",
            "UPDATE usage_events SET amount = NULL WHERE basis = 'reported'",
            "UPDATE usage_events SET amount = -1 WHERE basis = 'reported'",
            "UPDATE usage_events SET feature = 'futureFeature' WHERE rowid = 1",
            "UPDATE usage_events SET account = 'server:NOT-A-UUID' WHERE rowid = 1",
            "UPDATE usage_events SET currency = 'elevenLabsCredits' WHERE account = 'openRouter'",
            "UPDATE usage_events SET audio_seconds = -2 WHERE rowid = 1",
            "UPDATE usage_events SET model = '' WHERE rowid = 1",
            "UPDATE usage_events SET created_at = 'yesterday' WHERE rowid = 1",
            "INSERT INTO usage_events VALUES (NULL, 1, 'agent', 'openAI', 'm', 'usd', NULL, 'unavailable', 0)"
        ]
        for (index, sql) in cases.enumerated() {
            let database = try await validJournal("row-\(index)")
            try exec(database, sql)
            assertRejected(database)
        }
    }

    // MARK: - Restore merge

    func testRestoreKeepsThisMacsEarlierRowsWithoutDuplicatesOrDowngrades() async throws {
        let archived = url("archive/ai-usage.sqlite"), archiveStore = AIUsageStore(url: archived)
        try await archiveStore.insert(event("shared-estimate", 0.01, basis: .estimated))
        try await archiveStore.insert(event("shared-reported", 0.02, basis: .reported))
        try await archiveStore.insert(event("only-backup", 0.03))
        let restored = try await exported(archiveStore, "restored")

        let prior = url("prior/ai-usage.sqlite"), priorStore = AIUsageStore(url: prior)
        try await priorStore.insert(event("shared-estimate", 0.011, basis: .reported))
        try await priorStore.insert(event("shared-reported", 0.5, basis: .estimated))
        try await priorStore.insert(event("only-this-mac", nil, account: .elevenLabs, feature: .agentVoice,
                                          model: "scribe_v2_realtime", audio: 9))

        let warning = try ArtifactUsageBackup.mergePrior(database: prior, rollbackJournal: nil,
                                                          into: restored, scratch: url("scratch"))
        XCTAssertNil(warning)
        let rows = Dictionary(uniqueKeysWithValues: try await allEvents(restored).map { ($0.id, $0) })
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows["shared-estimate"]?.amount, 0.011)
        XCTAssertEqual(rows["shared-estimate"]?.basis, .reported)
        XCTAssertEqual(rows["shared-reported"]?.amount, 0.02, "an estimate never replaces a reported price")
        XCTAssertEqual(rows["only-backup"]?.amount, 0.03)
        XCTAssertEqual(rows["only-this-mac"]?.currency, .elevenLabsCredits)
        XCTAssertEqual(rows["only-this-mac"]?.audioSeconds, 9)
        XCTAssertEqual(try ArtifactUsageBackup.validate(database: restored), 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url("scratch").path), [])
    }

    func testCheckpointCopyIsNeverModifiedByTheMerge() async throws {
        let restoredStore = AIUsageStore(url: url("archive/ai-usage.sqlite"))
        try await restoredStore.insert(event("a", 0.01))
        let restored = try await exported(restoredStore, "restored")
        let prior = url("prior/ai-usage.sqlite")
        try await AIUsageStore(url: prior).insert(event("b", 0.02))
        let before = try digest(prior)
        _ = try ArtifactUsageBackup.mergePrior(database: prior, rollbackJournal: nil, into: restored, scratch: url("scratch"))
        XCTAssertEqual(try digest(prior), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prior.path + "-journal"))
    }

    func testUnreadableEarlierJournalIsReportedAndLeavesTheRestoredCopyIntact() async throws {
        let restoredStore = AIUsageStore(url: url("archive/ai-usage.sqlite"))
        try await restoredStore.insert(event("a", 0.01))
        let restored = try await exported(restoredStore, "restored")
        let before = try digest(restored)
        let prior = url("prior.sqlite")
        try Data(repeating: 0x00, count: 8192).write(to: prior)
        let warning = try ArtifactUsageBackup.mergePrior(database: prior, rollbackJournal: nil,
                                                          into: restored, scratch: url("scratch"))
        XCTAssertNotNil(warning)
        XCTAssertEqual(try digest(restored), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prior.path), "kept for the recovery folder")
    }

    func testNoEarlierJournalIsANoOp() async throws {
        let store = AIUsageStore(url: url("archive/ai-usage.sqlite"))
        try await store.insert(event("a", 0.01))
        let restored = try await exported(store, "restored")
        let before = try digest(restored)
        XCTAssertNil(try ArtifactUsageBackup.mergePrior(database: nil, rollbackJournal: nil, into: restored, scratch: url("s")))
        XCTAssertNil(try ArtifactUsageBackup.mergePrior(database: url("missing.sqlite"), rollbackJournal: nil,
                                                       into: restored, scratch: url("s")))
        XCTAssertEqual(try digest(restored), before)
    }

    func testCheckpointTargetsCoverEverySQLiteSidecarOfTheFlavorJournal() {
        let locations = ArtifactBackupLocations.isolated(root: root)
        XCTAssertEqual(locations.usageDatabase.deletingLastPathComponent(), locations.bundleRoot)
        XCTAssertEqual(ArtifactUsageBackup.checkpointTargets(locations: locations).map(\.lastPathComponent),
                       ["ai-usage.sqlite", "ai-usage.sqlite-journal", "ai-usage.sqlite-wal", "ai-usage.sqlite-shm"])
        XCTAssertNoThrow(try ArtifactBackupPath.validate(ArtifactUsageBackup.archivePath))
    }
}

