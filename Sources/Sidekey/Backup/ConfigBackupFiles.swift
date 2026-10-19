import Foundation

/// Disk work is serialized away from the UI. Each Mac writes its own directory
/// and every version has a unique name: a second Mac cannot overwrite the first.
actor ConfigBackupFiles {
    nonisolated let root: URL
    init(root: URL) { self.root = root }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(BuildConfig.bundleID, isDirectory: true)
            .appendingPathComponent("settings-backups", isDirectory: true)
    }

    func save(_ data: Data, id: UUID, in directory: URL? = nil) throws -> URL {
        let target = directory ?? root
        try Self.ensurePrivateDirectory(target)
        let file = target.appendingPathComponent(id.uuidString.lowercased() + ".exodiabackup")
        try Self.write(data, to: file)
        return file
    }

    func read(_ file: URL) throws -> Data { try Self.readFile(file) }

    func load(key: Data) throws -> [ConfigBackupSnapshot] { try load(keys: [key]) }

    func load(keys: [Data]) throws -> [ConfigBackupSnapshot] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try Self.checkDirectory(root)
        let files = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "exodiabackup" }
        guard files.count <= 1000 else { throw ConfigBackupError.tooLarge }
        // A bad version must not hide all the remaining healthy versions. Keep
        // unreadable files on disk; do not prune or reset them on a read error.
        let keyring = Dictionary(keys.map { (ConfigBackupArchive.keyID($0), $0) }, uniquingKeysWith: { first, _ in first })
        return files.compactMap { file -> ConfigBackupSnapshot? in
            guard let data = try? Self.readFile(file), let envelope = try? ConfigBackupArchive.readEnvelope(data),
                  let key = keyring[envelope.keyID] else { return nil }
            return try? ConfigBackupArchive.open(data, key: key)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Only callers' successfully read, explicitly expired versions may be
    /// pruned. Unreadable versions are never treated as expired.
    func prune(removing ids: Set<UUID>) throws {
        try Self.checkDirectory(root)
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where url.pathExtension == "exodiabackup" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), ids.contains(id) else { continue }
            // Never follow an unexpected link while doing maintenance.
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    static func readFile(_ file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ConfigBackupError.unsafePath }
        guard let count = values.fileSize, count <= ConfigBackupArchive.maxBytes else { throw ConfigBackupError.tooLarge }
        let data = try Data(contentsOf: file)
        guard data.count <= ConfigBackupArchive.maxBytes else { throw ConfigBackupError.tooLarge }
        return data
    }

    static func write(_ data: Data, to file: URL) throws {
        guard data.count <= ConfigBackupArchive.maxBytes else { throw ConfigBackupError.tooLarge }
        try checkDirectory(file.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: file.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ConfigBackupError.unsafePath }
        }
        // Set 0600 on the temporary file BEFORE rename; Foundation's .atomic
        // alone would expose new files under the user's umask until chmod.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".backup-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else { throw ConfigBackupError.saveFailed }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw ConfigBackupError.saveFailed }
        guard rename(temporary.path, file.path) == 0 else { throw ConfigBackupError.saveFailed }
        try synchronizeDirectory(file.deletingLastPathComponent())
    }

    static func ensurePrivateDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) { try checkDirectory(directory); return }
        let parent = directory.deletingLastPathComponent()
        try ensurePrivateDirectory(parent)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try synchronizeDirectory(parent)
    }

    static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ConfigBackupError.saveFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ConfigBackupError.saveFailed }
    }

    static func checkDirectory(_ directory: URL) throws {
        // All existing ancestors must be real directories. In particular, a
        // supplied backup folder must not redirect writes through a symlink.
        var current = directory.standardizedFileURL
        while current.path != "/" {
            let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            let type = attributes[.type] as? FileAttributeType
            // Darwin exposes /var and /tmp through system-owned aliases. A
            // normal temporary URL therefore legitimately traverses these;
            // user-controlled symlinks are still refused at every component.
            let systemAlias = ["/var": "/private/var", "/tmp": "/private/tmp" ][current.path]
            let linkTarget = type == .typeSymbolicLink ? try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) : nil
            let allowedAlias = type == .typeSymbolicLink && systemAlias != nil
                && (linkTarget == systemAlias || linkTarget.map { "/" + $0 } == systemAlias)
            guard type == .typeDirectory || allowedAlias else { throw ConfigBackupError.unsafePath }
            current.deleteLastPathComponent()
        }
    }
}
