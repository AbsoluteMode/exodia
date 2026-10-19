import Foundation

/// A durable user request, never a recovery secret. Keep it until every
/// destination confirms cleanup; a network failure must not look like revocation.
/// WHY: .project-docs/decisions/2026-10-19-backup-management.md
struct BackupMaintenancePlan: Codable, Equatable {
    enum Kind: String, Codable { case replaceCode, deleteBackups }
    enum Phase: String, Codable { case preparing, cleanup }
    var kind: Kind
    var phase: Phase = .preparing
    var destinationID: String?
    var newKeyID: String
    var replacement: ArtifactBackupSummary?
    var resumeAutomatic: Bool
}

extension BackupLocalStore {
    private var maintenanceURL: URL { root.appendingPathComponent("maintenance.json") }

    func maintenance() throws -> BackupMaintenancePlan? {
        guard FileManager.default.fileExists(atPath: maintenanceURL.path) else { return nil }
        let plan = try JSONDecoder().decode(BackupMaintenancePlan.self, from: ConfigBackupFiles.readFile(maintenanceURL))
        guard plan.newKeyID.count == 64, plan.newKeyID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              plan.kind != .replaceCode || plan.destinationID != nil,
              plan.phase != .cleanup || plan.kind == .deleteBackups || plan.replacement != nil else {
            throw ConfigBackupError.invalidArchive
        }
        return plan
    }

    func saveMaintenance(_ plan: BackupMaintenancePlan) throws {
        try ConfigBackupFiles.ensurePrivateDirectory(root)
        try ConfigBackupFiles.write(JSONEncoder().encode(plan), to: maintenanceURL)
    }

    func finishMaintenance() throws {
        try FileManager.default.removeItem(at: maintenanceURL)
        try ConfigBackupFiles.synchronizeDirectory(root)
    }

    /// Remove only full-backup files owned by this feature. Settings history
    /// and restore transaction checkpoints have independent retention contracts.
    func deleteFullBackups(except keptID: UUID?) throws {
        try Self.deleteArchiveFiles(in: root, except: keptID, includeUploadFiles: true)
        let previewRoot = root.appendingPathComponent("restore-work", isDirectory: true)
        try Self.deleteArchiveFiles(in: previewRoot, except: nil)
        // Do not depend on a readable catalog to erase damaged backup files.
        let kept = try keptID == nil ? [] : records().filter { $0.summary.id == keptID }
        try ConfigBackupFiles.write(JSONEncoder().encode(kept), to: root.appendingPathComponent("catalog.json"))
    }

    static func deleteArchiveFiles(in folder: URL, except keptID: UUID?, includeUploadFiles: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try ConfigBackupFiles.checkDirectory(folder)
        let files = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for file in files {
            let name = file.lastPathComponent
            let archiveID = file.pathExtension == "exodiabackup" ? UUID(uuidString: file.deletingPathExtension().lastPathComponent) : nil
            let pieces = name.split(separator: ".")
            let upload = includeUploadFiles && pieces.count == 3 && UUID(uuidString: String(pieces[0])) != nil
                && pieces[1].count == 16 && pieces[1].allSatisfy(\.isHexDigit) && pieces[2] == "upload"
            let partial = name.hasPrefix(".copy-") && UUID(uuidString: String(name.dropFirst(6))) != nil
            guard (archiveID != nil && archiveID != keptID) || upload || partial else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ConfigBackupError.unsafePath }
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: file)
        }
        try ConfigBackupFiles.synchronizeDirectory(folder)
    }
}
