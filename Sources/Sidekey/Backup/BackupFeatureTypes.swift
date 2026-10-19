import Foundation

/// Portable content groups. Machine permissions and executable runtime state
/// are intentionally outside the restore contract.
enum ArtifactBackupSection: String, Codable, CaseIterable, Identifiable {
    case settings, credentials, caseVault, meetings, history, workspace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .settings: return "Settings"
        case .credentials: return "Provider keys"
        case .caseVault: return "Case"
        case .meetings: return "Meetings & recordings"
        case .history: return "History & saved images"
        case .workspace: return "Dashboards & agent instructions"
        }
    }
}

struct ArtifactBackupSummary: Codable, Equatable, Identifiable {
    var id: UUID
    var createdAt: Date
    var totalBytes: Int64
    var fileCount: Int
    var sections: Set<ArtifactBackupSection>

    /// The wire date is rounded by the archive's ISO-8601 encoder.
    func matchesArchive(_ other: Self) -> Bool {
        id == other.id && totalBytes == other.totalBytes && fileCount == other.fileCount
            && sections == other.sections && abs(createdAt.timeIntervalSince(other.createdAt)) < 1
    }
}

struct ArtifactBackupPreview: Equatable {
    var summary: ArtifactBackupSummary
    var warnings: [String]
}

enum BackupVersionLocation: Equatable { case local, folder, github, localAndFolder, localAndGitHub }

struct BackupVersion: Identifiable, Equatable {
    var id: String
    var createdAt: Date
    var size: Int64
    var localURL: URL?
    var remoteID: Int?
    var location: BackupVersionLocation = .local
    var pendingCopy = false
    var purpose: String?
}

/// Narrow seams keep clean-profile controller tests away from the real
/// workspace, network and Keychain.
struct BackupEngineActions {
    var create: @MainActor (URL, Data) async throws -> ArtifactBackupSummary
    var inspect: @MainActor (URL, Data) async throws -> ArtifactBackupPreview
    var stage: @MainActor (URL, Data, Set<ArtifactBackupSection>) async throws -> Void
    var cancelPlanned: @MainActor () throws -> Bool = { false }
    var checkpoint: @MainActor () -> ArtifactRecoveryCheckpoint? = { nil }
    var parked: @MainActor () -> [ArtifactParkedItem] = { [] }
    var activate: @MainActor (ArtifactParkedItem) throws -> Void = { _ in }
    static var live: Self {
        Self(create: { try await ArtifactBackupEngine.shared.createArchive(at: $0, key: $1) },
             inspect: { try await ArtifactBackupEngine.shared.inspectArchive(at: $0, key: $1) },
             stage: { try await ArtifactBackupEngine.shared.stageRestore(from: $0, key: $1, sections: $2) },
             cancelPlanned: { try ArtifactBackupEngine.shared.cancelPlannedRestore() },
             checkpoint: { ArtifactBackupEngine.shared.recoveryCheckpoint() },
             parked: { ArtifactBackupEngine.shared.parkedRestoredItems() },
             activate: { try ArtifactBackupEngine.shared.activateParkedItem($0) })
    }
}
