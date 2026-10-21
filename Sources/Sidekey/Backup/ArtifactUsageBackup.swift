import Foundation
import SQLite3

/// Costs history (`ai-usage.sqlite`) inside the history section.
///
/// The journal is unique local data: recorded routes, provider references and
/// prices cannot be rebuilt from current settings. It holds metadata only
/// (IDs, times, feature/account/model, currency, amount, price basis, audio
/// seconds) and never credentials, endpoint URLs, prompts, transcripts or
/// audio. The snapshot is taken by `AIUsageStore` on its own connection; this
/// type is the single validator shared by export, archive verification and
/// restore, plus the restore-time merge of this Mac's earlier rows.
/// WHY: .project-docs/decisions/2026-10-21-backup-reliability.md
enum ArtifactUsageBackup {
    static let fileName = "ai-usage.sqlite"
    static let archivePath = "history/db/" + fileName
    static let label = "Costs history"
    static let maxRows = 1_000_000
    static let maxBytes: Int64 = 512 * 1024 * 1024

    private static let columns: [(name: String, notNull: Bool, primaryKey: Bool)] = [
        ("id", false, true), ("created_at", true, false), ("feature", true, false),
        ("account", true, false), ("model", true, false), ("currency", true, false),
        ("amount", false, false), ("basis", true, false), ("audio_seconds", true, false)
    ]

    /// Replacing the journal also moves aside every SQLite sidecar: a restored
    /// file next to the previous hot journal would be rolled back into a
    /// corrupt pair. Callers check these only when the archive carries the
    /// journal, so an older archive leaves this Mac's Costs history untouched.
    static func checkpointTargets(locations: ArtifactBackupLocations) -> [URL] {
        let database = locations.usageDatabase
        return [database] + ["-journal", "-wal", "-shm"].map {
            database.deletingLastPathComponent().appendingPathComponent(database.lastPathComponent + $0)
        }
    }

    // MARK: - Validation

    /// Schema and every row must be exactly what `AIUsageStore` writes. No
    /// other table, view or trigger is accepted: a restored trigger would run
    /// on the next recorded request. Returns the row count.
    @discardableResult
    static func validate(database: URL) throws -> Int {
        let handle = try openImmutable(database)
        defer { sqlite3_close(handle) }
        return try validate(handle: handle)
    }

    private static func validate(handle: OpaquePointer) throws -> Int {
        guard try scalarText(handle, "PRAGMA integrity_check") == "ok" else { throw invalid }
        try checkSchema(handle)
        return try forEachRow(handle) { _ in }
    }

    private static func checkSchema(_ handle: OpaquePointer) throws {
        var objects: [String: String] = [:]
        try step(handle, "SELECT type, name FROM sqlite_master") { statement in
            guard let type = text(statement, 0), let name = text(statement, 1) else { throw invalid }
            objects[name] = type
            guard objects.count <= 3 else { throw invalid }
        }
        guard objects["usage_events"] == "table", objects["usage_date"] == "index",
              objects.allSatisfy({ ["usage_events", "usage_date", "sqlite_autoindex_usage_events_1"].contains($0.key) }),
              objects["sqlite_autoindex_usage_events_1"] ?? "index" == "index" else { throw invalid }
        var found: [(String, Bool, Bool)] = []
        try step(handle, "PRAGMA table_info(usage_events)") { statement in
            guard let name = text(statement, 1) else { throw invalid }
            found.append((name, sqlite3_column_int(statement, 3) != 0, sqlite3_column_int(statement, 5) != 0))
        }
        guard found.count == columns.count,
              zip(found, columns).allSatisfy({ $0.0 == $1.name && $0.1 == $1.notNull && $0.2 == $1.primaryKey }) else {
            throw invalid
        }
        var indexed: [String] = []
        try step(handle, "PRAGMA index_info(usage_date)") { statement in
            guard let name = text(statement, 2) else { throw invalid }
            indexed.append(name)
        }
        guard indexed == ["created_at"] else { throw invalid }
    }

    /// Mirrors `AIUsageStore.insert` plus what `events(from:to:)` must decode.
    private static func validRow(_ statement: OpaquePointer) throws -> AIUsageEvent {
        func string(_ index: Int32, limit: Int) throws -> String {
            guard sqlite3_column_type(statement, index) == SQLITE_TEXT, let value = text(statement, index),
                  !value.isEmpty, value.utf8.count <= limit, !value.contains("\0") else { throw invalid }
            return value
        }
        func real(_ index: Int32) throws -> Double {
            let type = sqlite3_column_type(statement, index)
            guard type == SQLITE_FLOAT || type == SQLITE_INTEGER else { throw invalid }
            let value = sqlite3_column_double(statement, index)
            guard value.isFinite else { throw invalid }
            return value
        }
        let id = try string(0, limit: 1024)
        let createdAt = try real(1)
        guard let feature = AIFeature(rawValue: try string(2, limit: 64)),
              let account = ProviderAccount(storageID: try string(3, limit: 64)) else { throw invalid }
        let model = try string(4, limit: 2048)
        guard model.count <= 512,
              let currency = AIUsageCurrency(rawValue: try string(5, limit: 64)),
              let basis = AIUsageBasis(rawValue: try string(7, limit: 64)) else { throw invalid }
        var amount: Double?
        if sqlite3_column_type(statement, 6) != SQLITE_NULL { amount = try real(6) }
        let audio = try real(8)
        let context = AIUsageContext(feature: feature, account: account, model: model)
        guard currency == context.currency, audio >= 0, amount.map({ $0 >= 0 }) ?? true,
              (amount == nil) == (basis == .unavailable) else { throw invalid }
        return AIUsageEvent(id: id, createdAt: Date(timeIntervalSince1970: createdAt), context: context,
                            currency: currency, amount: amount, basis: basis, audioSeconds: audio)
    }

    @discardableResult
    private static func forEachRow(_ handle: OpaquePointer, _ body: (AIUsageEvent) throws -> Void) throws -> Int {
        var count = 0
        try step(handle, "SELECT * FROM usage_events ORDER BY rowid") { statement in
            count += 1
            guard count <= maxRows else { throw ArtifactBackupError.tooLarge }
            try body(try validRow(statement))
        }
        return count
    }

    // MARK: - Restore merge

    /// After the archive's journal is written in place, rows this Mac recorded
    /// before the restore are added back with the store's own upsert rule:
    /// IDs never duplicate and a price is never downgraded. A restored journal
    /// therefore cannot hide spending that happened only on this Mac. The
    /// earlier file and its rollback journal are read from private copies, so
    /// the checkpoint stays untouched for rollback. An unreadable earlier
    /// journal is not merged and remains in the restore's recovery folder.
    /// Returns a warning when this Mac's earlier rows could not be merged.
    static func mergePrior(database prior: URL?, rollbackJournal: URL?, writeAheadLog: URL? = nil, into restored: URL,
                           scratch: URL) throws -> String? {
        guard let prior, FileManager.default.fileExists(atPath: prior.path) else { return nil }
        let work = scratch.appendingPathComponent("usage-merge-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = work.appendingPathComponent(fileName)
        var events: [AIUsageEvent] = []
        do {
            try FileManager.default.copyItem(at: prior, to: copy)
            if let rollbackJournal, FileManager.default.fileExists(atPath: rollbackJournal.path) {
                try FileManager.default.copyItem(at: rollbackJournal,
                                                 to: work.appendingPathComponent(fileName + "-journal"))
            }
            if let writeAheadLog, FileManager.default.fileExists(atPath: writeAheadLog.path) {
                try FileManager.default.copyItem(at: writeAheadLog,
                                                 to: work.appendingPathComponent(fileName + "-wal"))
            }
            // Read-write only on the private copy: SQLite rolls back an
            // interrupted transaction from its hot journal before reading.
            var handle: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
                if let handle { sqlite3_close(handle) }
                throw invalid
            }
            defer { sqlite3_close(handle) }
            guard try scalarText(handle, "PRAGMA integrity_check") == "ok" else { throw invalid }
            try checkSchema(handle)
            try forEachRow(handle) { events.append($0) }
        } catch {
            return "Costs history recorded on this Mac before the restore could not be read. It is kept in the restore's recovery folder."
        }
        guard !events.isEmpty else { return nil }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(restored.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw ArtifactBackupError.writeFailed
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2000)
        try validate(handle: handle)
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw ArtifactBackupError.writeFailed }
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, AIUsageStore.upsertSQL, -1, &statement, nil) == SQLITE_OK else {
                throw ArtifactBackupError.writeFailed
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for event in events {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                func bind(_ value: String, _ index: Int32) { sqlite3_bind_text(statement, index, value, -1, transient) }
                bind(event.id, 1); sqlite3_bind_double(statement, 2, event.createdAt.timeIntervalSince1970)
                bind(event.context.feature.rawValue, 3); bind(event.context.account.storageID, 4)
                bind(event.context.model, 5); bind(event.currency.rawValue, 6)
                if let amount = event.amount { sqlite3_bind_double(statement, 7, amount) }
                else { sqlite3_bind_null(statement, 7) }
                bind(event.basis.rawValue, 8); sqlite3_bind_double(statement, 9, event.audioSeconds)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw ArtifactBackupError.writeFailed }
            }
            guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw ArtifactBackupError.writeFailed }
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return nil
    }

    // MARK: - SQLite helpers

    private static var invalid: ArtifactBackupError { .invalidContent(label) }

    /// Archive copies and fresh snapshots have no journal; `immutable` keeps
    /// SQLite from creating or honoring any sidecar next to them.
    private static func openImmutable(_ database: URL) throws -> OpaquePointer {
        let values = try? database.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { throw invalid }
        guard Int64(values?.fileSize ?? 0) <= maxBytes else { throw ArtifactBackupError.tooLarge }
        var components = URLComponents()
        components.scheme = "file"
        components.path = database.path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        var handle: OpaquePointer?
        guard let uri = components.string,
              sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw invalid
        }
        return handle
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private static func scalarText(_ handle: OpaquePointer, _ sql: String) throws -> String? {
        var result: String?
        try step(handle, sql) { statement in if result == nil { result = text(statement, 0) } }
        return result
    }

    private static func step(_ handle: OpaquePointer, _ sql: String,
                             _ row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw invalid }
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw invalid }
            try row(statement)
        }
    }
}

extension ArtifactBackupLocations {
    /// `AIUsageStore.shared` lives directly in the flavor's bundle root.
    var usageDatabase: URL { bundleRoot.appendingPathComponent(ArtifactUsageBackup.fileName, isDirectory: false) }
}

/// Staging seam: production passes `AIUsageStore.shared`, so the snapshot is
/// serialized with the app's only writer. Tests pass an isolated store.
protocol ArtifactUsageExporting: Sendable {
    func exportArtifactGeneration(into directory: URL) async throws -> URL?
}

extension AIUsageStore: ArtifactUsageExporting {}
