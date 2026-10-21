import CryptoKit
import Foundation
@testable import Sidekey

/// In-memory credential store. Keeps the whole backup/restore path away from
/// the user's real Keychain, which the restore tests must never touch.
final class MemoryTokenStore: TokenStore {
    private(set) var value: String?
    var failOnRead = false
    var failOnSave = false

    init(_ value: String? = nil) { self.value = value }

    func save(_ token: String) throws {
        if failOnSave { throw KeychainError.unexpectedData }
        value = token
    }

    func read() throws -> String? {
        if failOnRead { throw KeychainError.unexpectedData }
        return value
    }

    func delete() throws { value = nil }
}

/// Synthetic Case vault key provider: no Keychain, and a clean profile mints
/// its own local key exactly like the real store would.
final class StubCaseVaultKeys: ArtifactCaseKeyProviding {
    private(set) var stored: SymmetricKey?
    private(set) var createdCount = 0
    var failOnRead = false

    init(stored: SymmetricKey? = nil) { self.stored = stored }

    func existingVaultKey() throws -> SymmetricKey? {
        if failOnRead { throw CaseVaultKeyStoreError.unexpectedData }
        return stored
    }

    func vaultKeyForRestore() throws -> SymmetricKey {
        if let stored { return stored }
        let key = SymmetricKey(size: .bits256)
        stored = key
        createdCount += 1
        return key
    }
}

/// A disposable Whytap profile: the real relative layout under a temporary
/// root, so the production path rules are what the tests exercise.
struct ArtifactBackupTestProfile {
    let root: URL
    let locations: ArtifactBackupLocations
    let defaults: UserDefaults
    let defaultsSuite: String
    var credentialStores: [String: MemoryTokenStore] = [:]
    let caseKeys: StubCaseVaultKeys
    let pendingKeyStore = MemoryTokenStore()
    let recoveryKeyStore = MemoryTokenStore()

    init(caseKey: SymmetricKey? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-backup-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        locations = .isolated(root: root)
        defaultsSuite = "artifact.backup.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: defaultsSuite)!
        caseKeys = StubCaseVaultKeys(stored: caseKey)
    }

    func environment(meetings: ArtifactMeetingsExporting? = nil,
                     history: ArtifactHistoryExporting? = nil,
                     faults: ArtifactBackupFaults = ArtifactBackupFaults()) -> ArtifactBackupEnvironment {
        var environment = ArtifactBackupEnvironment()
        environment.locations = locations
        environment.defaults = defaults
        environment.credentialStore = { [credentialStores] account in
            credentialStores[account] ?? MemoryTokenStore()
        }
        environment.caseVaultKeys = caseKeys
        environment.pendingKeyStore = pendingKeyStore
        environment.recoveryKeyStore = recoveryKeyStore
        environment.meetings = meetings
        environment.history = history
        environment.faults = faults
        return environment
    }

    mutating func addCredential(_ account: String, _ secret: String?) {
        credentialStores[account] = MemoryTokenStore(secret)
    }

    func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func contents(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }
}

enum ArtifactBackupTestKeys {
    static func make() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
}

/// Builds an archive from exact entry bytes, so a test can present content the
/// production writer would never produce: a future inline schema, a damaged
/// database, a missing required sidecar.
enum ArtifactBackupTestArchive {
    static func make(at url: URL, key: Data,
                     entries: [(path: String, section: ArtifactBackupSection, data: Data)],
                     sections: [ArtifactBackupSection]? = nil,
                     schema: Int = ArtifactBackupManifest.currentSchema,
                     warnings: [String] = []) throws -> ArtifactBackupManifest {
        let inline = entries.filter { ArtifactRestoreDestination.isInlinePath($0.path) }
            .sorted { $0.path < $1.path }
        let files = entries.filter { !ArtifactRestoreDestination.isInlinePath($0.path) }
            .sorted { $0.path < $1.path }
        let ordered = inline + files
        let manifest = ArtifactBackupManifest(
            schema: schema, id: UUID(), createdAt: Date(), flavor: BuildConfig.flavor.rawValue,
            appVersion: nil, appBuild: nil,
            sections: (sections ?? Array(Set(entries.map(\.section)))).sorted { $0.rawValue < $1.rawValue },
            entries: ordered.map {
                ArtifactBackupManifest.Entry(path: $0.path, section: $0.section,
                                             bytes: Int64($0.data.count),
                                             sha256: ArtifactBackupDigest.of($0.data))
            },
            contentBytes: ordered.reduce(Int64(0)) { $0 + Int64($1.data.count) },
            warnings: warnings)
        let data = try manifest.encoded()
        let writer = try ArtifactArchiveWriter(url: url, archiveKey: key)
        try writer.append(Data(ArtifactArchiveHeader.bigEndian32(UInt32(data.count))))
        try writer.append(data)
        for entry in ordered { try writer.append(entry.data) }
        try writer.finish()
        return manifest
    }

    static func settingsPayload(schema: Int = ArtifactSettingsPayload.currentSchema,
                                values: [String: ConfigBackupValue] = [:]) throws -> Data {
        try JSONEncoder.artifactBackup.encode(ArtifactSettingsPayload(schema: schema, values: values))
    }

    static func credentialsPayload(schema: Int = ArtifactCredentialsPayload.currentSchema,
                                   accounts: [String: String] = [:]) throws -> Data {
        try JSONEncoder.artifactBackup.encode(
            ArtifactCredentialsPayload(schema: schema, accounts: accounts))
    }
}
