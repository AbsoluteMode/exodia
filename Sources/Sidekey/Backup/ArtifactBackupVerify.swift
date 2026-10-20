import CryptoKit
import Foundation
import SQLite3

/// What a full verification pass learned about an archive.
struct ArtifactArchiveVerification: Sendable {
    var manifest: ArtifactBackupManifest
    var warnings: [String]
    /// Secrets and configurations that are applied through memory. Never
    /// written to a plaintext file, here or at restore time.
    var inline: [ArtifactRestoreDestination.Inline: Data]
    /// Notify source files whose configuration this build cannot read. Their
    /// bytes are preserved inertly instead of being dropped.
    var unreadableNotifySources: [String]
}

/// Authentication and digests prove an archive is intact; they prove nothing
/// about whether its contents are usable. Before anything is parked or
/// touched, the archive is replayed into a private generation: inline payloads
/// are decoded and schema-checked, the databases are opened and
/// integrity-checked, and every sidecar a row refers to must be present.
/// WHY: .project-docs/decisions/2026-10-19-config-backup.md
enum ArtifactArchiveVerifier {
    private static let meetingsDatabasePath = "meetings/db/meetings.sqlite"
    private static let historyDatabasePath = "history/db/history.sqlite"

    static func requiredPaths(for section: ArtifactBackupSection) -> [String] {
        switch section {
        case .settings: return ["settings/preferences.json"]
        case .credentials: return ["credentials/providers.json"]
        case .caseVault: return ["case/vault.enc", "case/vault.key"]
        case .meetings: return [meetingsDatabasePath]
        case .history: return [historyDatabasePath]
        case .workspace: return []
        }
    }

    static func verify(archiveAt url: URL, key: Data, sections: Set<ArtifactBackupSection>?,
                       scratch: URL) throws -> ArtifactArchiveVerification {
        let reader = try ArtifactArchiveReader(url: url, archiveKey: key)
        defer { reader.close() }
        let manifest = try ArtifactRestoreTransaction.readManifest(reader)
        let wanted = sections ?? Set(manifest.sections)
        guard wanted.isSubset(of: Set(manifest.sections)) else { throw ArtifactBackupError.missingSection }

        // Inline payloads must form the archive's head, so the restore can
        // validate them without reading gigabytes of audio first.
        var sawFile = false
        for entry in manifest.entries {
            if ArtifactRestoreDestination.isInlinePath(entry.path) {
                guard !sawFile else { throw ArtifactBackupError.damaged }
            } else { sawFile = true }
        }
        let paths = Set(manifest.entries.map(\.path))
        var lowercased = Set<String>()
        for path in manifest.entries.map(\.path) {
            guard lowercased.insert(path.lowercased()).inserted else {
                throw ArtifactBackupError.unsafeContent
            }
        }
        for section in wanted.sorted(by: { $0.rawValue < $1.rawValue }) {
            for required in requiredPaths(for: section) where !paths.contains(required) {
                throw ArtifactBackupError.incompleteArchive(required)
            }
            if section == .workspace, !manifest.entries.contains(where: { $0.section == .workspace }) {
                throw ArtifactBackupError.incompleteArchive("workspace")
            }
        }

        var inline: [ArtifactRestoreDestination.Inline: Data] = [:]
        var databases: [String: URL] = [:]
        for entry in manifest.entries {
            let isDatabase = entry.path == meetingsDatabasePath || entry.path == historyDatabasePath
            var inlineKind: ArtifactRestoreDestination.Inline?
            if wanted.contains(entry.section) {
                // Resolving every wanted path up front refuses unknown roots
                // and traversal before a single byte is written anywhere.
                let destination = try ArtifactRestoreDestination.resolve(entry.path, in: .production)
                if case .inline(let kind) = destination { inlineKind = kind }
            }
            if let kind = inlineKind {
                guard entry.bytes <= ArtifactBackupManifest.maxInlineBytes else {
                    throw ArtifactBackupError.tooLarge
                }
                var buffer = Data()
                var hasher = SHA256()
                try reader.forward(entry.bytes) { buffer.append($0); hasher.update(data: $0) }
                guard ArtifactBackupDigest.hex(hasher.finalize()) == entry.sha256 else {
                    throw ArtifactBackupError.damaged
                }
                inline[kind] = buffer
                continue
            }
            if isDatabase, wanted.contains(entry.section) {
                let file = scratch.appendingPathComponent(
                    entry.path == meetingsDatabasePath ? "meetings.sqlite" : "history.sqlite")
                try write(entry: entry, from: reader, to: file)
                databases[entry.path] = file
                continue
            }
            var hasher = SHA256()
            try reader.forward(entry.bytes) { hasher.update(data: $0) }
            guard ArtifactBackupDigest.hex(hasher.finalize()) == entry.sha256 else {
                throw ArtifactBackupError.damaged
            }
        }
        try reader.verifyEnd()

        var warnings = manifest.warnings
        var unreadableNotify: [String] = []
        if wanted.contains(.settings) { try validateSettings(inline[.settings]) }
        if wanted.contains(.credentials) { try validateCredentials(inline[.credentials]) }
        if wanted.contains(.caseVault) { try validateCase(inline[.caseVault], key: inline[.caseKey]) }
        if wanted.contains(.workspace) {
            for (kind, data) in inline {
                guard case .notifySource(let name) = kind else { continue }
                if !isReadableNotifySource(data, named: name) {
                    unreadableNotify.append(name)
                }
            }
            if !unreadableNotify.isEmpty {
                warnings.append("\(unreadableNotify.count) notification source file(s) cannot be read by this version. Their contents are restored as an inactive copy instead of being dropped.")
            }
        }
        if wanted.contains(.meetings), let database = databases[meetingsDatabasePath] {
            try validateMeetings(database, paths: paths)
        }
        if wanted.contains(.history), let database = databases[historyDatabasePath] {
            try validateHistory(database, paths: paths)
        }
        return ArtifactArchiveVerification(manifest: manifest, warnings: Array(warnings.prefix(64)),
                                           inline: inline, unreadableNotifySources: unreadableNotify)
    }

    // MARK: - Inline payloads

    static func validateSettings(_ data: Data?) throws {
        guard let data else { throw ArtifactBackupError.incompleteArchive("settings/preferences.json") }
        let payload: ArtifactSettingsPayload
        do { payload = try JSONDecoder.artifactBackup.decode(ArtifactSettingsPayload.self, from: data) }
        catch { throw ArtifactBackupError.invalidContent("settings") }
        try payload.validate()
    }

    static func validateCredentials(_ data: Data?) throws {
        guard let data else { throw ArtifactBackupError.incompleteArchive("credentials/providers.json") }
        let payload: ArtifactCredentialsPayload
        do { payload = try JSONDecoder.artifactBackup.decode(ArtifactCredentialsPayload.self, from: data) }
        catch { throw ArtifactBackupError.invalidContent("provider keys") }
        guard payload.schema <= ArtifactCredentialsPayload.currentSchema else {
            throw ArtifactBackupError.needsNewerApp
        }
        do { try ConfigBackupRegistry.validate([:], credentials: payload.accounts) }
        catch { throw ArtifactBackupError.invalidContent("provider keys") }
    }

    static func validateCase(_ vault: Data?, key: Data?) throws {
        guard let vault else { throw ArtifactBackupError.incompleteArchive("case/vault.enc") }
        guard let key, key.count == 32 else { throw ArtifactBackupError.incompleteArchive("case/vault.key") }
        let payload: CaseVaultPayload
        do { payload = try CaseVaultStore.decode(envelope: vault, using: SymmetricKey(data: key)) }
        catch CaseVaultStoreError.needsNewerApp { throw ArtifactBackupError.needsNewerApp }
        catch { throw ArtifactBackupError.invalidContent("Case") }
        guard payload.schemaVersion <= CaseVaultPayload.currentSchemaVersion else {
            throw ArtifactBackupError.needsNewerApp
        }
    }

    static func isReadableNotifySource(_ data: Data, named name: String) -> Bool {
        guard let script = try? JSONDecoder().decode(NotifyScript.self, from: data),
              (try? script.validate()) != nil, script.id + ".json" == name else { return false }
        return true
    }

    // MARK: - Databases

    private static func validateMeetings(_ database: URL, paths: Set<String>) throws {
        let handle = try open(database)
        defer { sqlite3_close(handle) }
        try checkIntegrity(handle, label: "meetings")
        let available = Set(paths.map { $0.lowercased() })
        for row in try query(handle, "SELECT id, progress_status FROM meetings") {
            guard row.count == 2, let id = row[0], let status = row[1] else {
                throw ArtifactBackupError.invalidContent("meetings catalog")
            }
            guard UUID(uuidString: id) != nil else {
                throw ArtifactBackupError.invalidContent("meetings catalog")
            }
            guard status == MeetingProgressStatus.ready.rawValue else { continue }
            let note = "meetings/notes/\(id).md".lowercased()
            guard available.contains(note) else {
                throw ArtifactBackupError.incompleteArchive("meetings/notes/\(id).md")
            }
        }
    }

    private static func validateHistory(_ database: URL, paths: Set<String>) throws {
        let handle = try open(database)
        defer { sqlite3_close(handle) }
        try checkIntegrity(handle, label: "history")
        let available = Set(paths.map { $0.lowercased() })
        let sql = """
            SELECT image_uuid, image_extension FROM clipboard_entries
            WHERE kind = 'image' AND image_uuid IS NOT NULL AND image_extension IS NOT NULL
            """
        for row in try query(handle, sql) {
            guard row.count == 2, let id = row[0], let ext = row[1] else {
                throw ArtifactBackupError.invalidContent("history")
            }
            let asset = "history/assets/\(id).\(ext)".lowercased()
            guard available.contains(asset) else {
                throw ArtifactBackupError.incompleteArchive("history/assets/\(id).\(ext)")
            }
        }
    }

    private static func open(_ database: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw ArtifactBackupError.invalidContent("database")
        }
        return handle
    }

    private static func checkIntegrity(_ handle: OpaquePointer, label: String) throws {
        let rows = try query(handle, "PRAGMA integrity_check")
        guard rows.first?.first == "ok" else { throw ArtifactBackupError.invalidContent(label) }
    }

    private static func query(_ handle: OpaquePointer, _ sql: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ArtifactBackupError.invalidContent("database")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        let columns = Int(sqlite3_column_count(statement))
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ArtifactBackupError.invalidContent("database") }
            rows.append((0..<columns).map { index in
                sqlite3_column_text(statement, Int32(index)).map { String(cString: $0) }
            })
            guard rows.count <= 200_000 else { throw ArtifactBackupError.tooLarge }
        }
        return rows
    }

    private static func write(entry: ArtifactBackupManifest.Entry, from reader: ArtifactArchiveReader,
                              to file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ArtifactBackupError.writeFailed
        }
        guard let handle = try? FileHandle(forWritingTo: file) else {
            throw ArtifactBackupError.writeFailed
        }
        var hasher = SHA256()
        do {
            try reader.forward(entry.bytes) { block in
                try handle.write(contentsOf: block)
                hasher.update(data: block)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw (error as? ArtifactBackupError) ?? ArtifactBackupError.writeFailed
        }
        guard ArtifactBackupDigest.hex(hasher.finalize()) == entry.sha256 else {
            throw ArtifactBackupError.damaged
        }
    }
}
