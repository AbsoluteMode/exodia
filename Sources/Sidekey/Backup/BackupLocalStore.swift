import CryptoKit
import Foundation

actor BackupLocalStore {
    struct UploadPreparation: Codable {
        var destinationID: String
        var baseID: UUID?
        var depth: Int
        var draftID: Int?
    }
    struct Record: Codable {
        var summary: ArtifactBackupSummary
        var remoteID: Int?
        var copiedAt: Date?
        var destinationID: String?
        var uploadedDepth: Int?
        var preparation: UploadPreparation?
        var purpose: String?
        var recoveryOnly: Bool?
    }
    nonisolated let root: URL
    init(root: URL = BackupLocalStore.defaultRoot) { self.root = root }
    static var defaultRoot: URL { ConfigBackupFiles.defaultRoot.deletingLastPathComponent().appendingPathComponent("user-backups", isDirectory: true) }
    private var catalog: URL { root.appendingPathComponent("catalog.json") }
    func archiveURL() throws -> URL {
        try ConfigBackupFiles.ensurePrivateDirectory(root)
        return root.appendingPathComponent(UUID().uuidString.lowercased() + ".exodiabackup")
    }
    func records() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: catalog.path) else { return [] }
        let data = try ConfigBackupFiles.readFile(catalog)
        guard let records = try? JSONDecoder().decode([Record].self, from: data), records.count <= 5000 else {
            throw ConfigBackupError.invalidArchive
        }
        return records.sorted { $0.summary.createdAt > $1.summary.createdAt }
    }
    func versions(destinationID: String? = nil) throws -> [BackupVersion] {
        try records().map { record in
            let copied = record.copiedAt != nil && (destinationID == nil || record.destinationID == destinationID)
            let location: BackupVersionLocation = !copied ? .local : (record.remoteID == nil ? .localAndFolder : .localAndGitHub)
            return BackupVersion(id: record.summary.id.uuidString, createdAt: record.summary.createdAt,
                          size: record.summary.totalBytes, localURL: fileURL(record.summary.id), remoteID: record.remoteID,
                          location: location, pendingCopy: !copied && record.recoveryOnly != true, purpose: record.purpose)
        }.filter { FileManager.default.fileExists(atPath: $0.localURL!.path) }
    }
    func fileURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + ".exodiabackup") }
    func record(_ summary: ArtifactBackupSummary, from file: URL, purpose: String? = nil, recoveryOnly: Bool = false) throws -> URL {
        var records = try records()
        let destination = fileURL(summary.id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ConfigBackupError.saveFailed }
        try FileManager.default.moveItem(at: file, to: destination)
        records.insert(Record(summary: summary, purpose: purpose, recoveryOnly: recoveryOnly), at: 0)
        do { try ConfigBackupFiles.write(JSONEncoder().encode(records), to: catalog) }
        catch { try? FileManager.default.moveItem(at: destination, to: file); throw error }
        return destination
    }
    func markCopied(id: UUID, destinationID: String, remoteID: Int? = nil, depth: Int = 0, date: Date = Date()) throws {
        var records = try records()
        guard let index = records.firstIndex(where: { $0.summary.id == id }) else { throw ConfigBackupError.invalidArchive }
        records[index].copiedAt = date; records[index].remoteID = remoteID; records[index].destinationID = destinationID
        records[index].uploadedDepth = depth; records[index].preparation = nil
        try ConfigBackupFiles.write(JSONEncoder().encode(records), to: catalog)
        // Keep every unsent copy and the latest 30 successfully copied
        // generations. Remote copies are not automatically deleted.
        let expired = Array(records.filter { $0.copiedAt != nil }.dropFirst(30))
        let ids = Set(expired.map { $0.summary.id })
        if !ids.isEmpty {
            for record in expired {
                let url = fileURL(record.summary.id)
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true && values?.isSymbolicLink != true { try? FileManager.default.removeItem(at: url) }
            }
            // Only forget entries whose file was successfully removed.
            records.removeAll { ids.contains($0.summary.id) && !FileManager.default.fileExists(atPath: fileURL($0.summary.id).path) }
            try ConfigBackupFiles.write(JSONEncoder().encode(records), to: catalog)
        }
    }
    func uploadFileURL(id: UUID, destinationID: String) -> URL {
        let suffix = SHA256.hash(data: Data(destinationID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(id.uuidString.lowercased() + "." + suffix + ".upload")
    }
    func recordPreparation(id: UUID, preparation: UploadPreparation) throws {
        var values = try records()
        guard let index = values.firstIndex(where: { $0.summary.id == id }),
              (0...32).contains(preparation.depth), preparation.baseID != id else { throw ConfigBackupError.invalidArchive }
        values[index].preparation = preparation
        try ConfigBackupFiles.write(JSONEncoder().encode(values), to: catalog)
    }

    func recordDraft(id: UUID, destinationID: String, draftID: Int) throws {
        var values = try records()
        guard draftID > 0, let index = values.firstIndex(where: { $0.summary.id == id }),
              values[index].preparation?.destinationID == destinationID else { throw ConfigBackupError.invalidArchive }
        values[index].preparation?.draftID = draftID
        try ConfigBackupFiles.write(JSONEncoder().encode(values), to: catalog)
    }

    func pendingCopies(destinationID: String) throws -> [Record] { try records().filter { $0.recoveryOnly != true && ($0.copiedAt == nil || $0.destinationID != destinationID) } }

    /// No plaintext is involved; nevertheless verify the copied ciphertext
    /// before marking the folder destination complete.
    static func copyArchive(_ source: URL, to destination: URL) throws {
        try ConfigBackupFiles.checkDirectory(source.deletingLastPathComponent())
        try ConfigBackupFiles.ensurePrivateDirectory(destination.deletingLastPathComponent())
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ConfigBackupError.unsafePath }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            guard try digest(source) == digest(destination) else { throw ConfigBackupError.saveFailed }
            return
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".copy-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ConfigBackupError.saveFailed }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: temporary)
        defer { try? input.close(); try? output.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes); try output.write(contentsOf: bytes)
        }
        try output.synchronize(); try output.close()
        guard Data(hash.finalize()) == (try digest(temporary)) else { throw ConfigBackupError.saveFailed }
        guard rename(temporary.path, destination.path) == 0 else { throw ConfigBackupError.saveFailed }
        try ConfigBackupFiles.synchronizeDirectory(destination.deletingLastPathComponent())
    }
    private static func digest(_ file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ConfigBackupError.unsafePath }
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation(); hash.update(data: bytes)
        }
        return Data(hash.finalize())
    }
}

/// Settings blocks use the same durable restore transaction as complete
/// artifacts. The inline settings schema carries an explicit section mask;
/// other preferences are read at apply time, so later edits are preserved.
enum BackupSettingsBlockRestore {
    private struct BlockPayload: Encodable {
        let schema = 2
        var values: [String: ConfigBackupValue]
        var selectedSections: [ConfigBackupSection]
    }
    static func archive(_ snapshot: ConfigBackupSnapshot, section: ConfigBackupSection,
                        key: Data, directory: URL = ConfigBackupFiles.defaultRoot) throws -> (URL, ArtifactBackupSection) {
        try ConfigBackupRegistry.validate(snapshot.preferences, credentials: snapshot.credentials)
        let folder = directory.appendingPathComponent("block-staging", isDirectory: true)
        try ConfigBackupFiles.ensurePrivateDirectory(folder)
        let file = folder.appendingPathComponent(UUID().uuidString + ".exodiabackup")
        let group: ArtifactBackupSection = section == .credentials ? .credentials : .settings
        let path: String, payload: Data
        if section == .credentials {
            path = "credentials/providers.json"
            payload = try JSONEncoder.artifactBackup.encode(ArtifactCredentialsPayload(accounts: snapshot.credentials ?? [:]))
        } else {
            path = "settings/preferences.json"
            payload = try JSONEncoder.artifactBackup.encode(BlockPayload(
                values: snapshot.preferences.filter { ConfigBackupRegistry.entries[$0.key]?.section == section },
                selectedSections: [section]))
        }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifest = ArtifactBackupManifest(id: UUID(), createdAt: snapshot.createdAt,
            flavor: BuildConfig.flavor.rawValue, sections: [group],
            entries: [.init(path: path, section: group, bytes: Int64(payload.count), sha256: digest)],
            contentBytes: Int64(payload.count), warnings: [])
        let bytes = try manifest.encoded()
        let writer = try ArtifactArchiveWriter(url: file, archiveKey: key)
        do {
            try writer.append(Data(ArtifactArchiveHeader.bigEndian32(UInt32(bytes.count))))
            try writer.append(bytes); try writer.append(payload); try writer.finish()
            return (file, group)
        } catch { writer.cancel(); throw error }
    }
}
