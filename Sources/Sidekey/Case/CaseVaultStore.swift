import CryptoKit
import Foundation

enum CaseVaultStoreError: Error, Equatable {
    case missingFile
    case invalidEnvelope
    case unsupportedEnvelope
    /// Vault decrypted successfully but was written by a newer build
    /// (schemaVersion > currentSchemaVersion). The user must update the app;
    /// the data is intact and must NOT be reset.
    case needsNewerApp
}

struct CaseVaultEnvelope: Codable, Equatable {
    let version: Int
    let algorithm: String
    let nonce: String
    let ciphertext: String
    let tag: String
}

struct CaseVaultStore {
    static let envelopeVersion = 1
    static let algorithm = "AES-GCM"

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = Self.defaultFileURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// One vault per flavor. The key lives under the flavor's Keychain
    /// service, so a beta/dev build sharing the prod file could only ever see
    /// it as unreadable, and resetting it there wiped the prod vault.
    /// WHY: docs/decisions/2026-10-08-case-vault-never-lost.md
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(BuildConfig.bundleID, isDirectory: true)
            .appendingPathComponent("case-vault.json.enc", isDirectory: false)
    }

    /// The vault as it was before the latest save.
    var backupFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".bak")
    }

    func load(using key: SymmetricKey) throws -> CaseVaultPayload {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw CaseVaultStoreError.missingFile
        }

        let envelopeData = try Data(contentsOf: fileURL)
        // decode migrates schema 1 to 2 in memory; the file is rewritten as
        // schema 2 on the next save, which keeps the schema-1 bytes in `.bak`.
        // A newer schema throws needsNewerApp (decryption succeeded, data is
        // intact; must NOT be treated as undecryptable or offer Reset). An
        // older, unknown schema throws unsupportedEnvelope.
        return try Self.decode(envelope: envelopeData, using: key)
    }

    /// Decrypts a vault envelope that is already in memory.
    ///
    /// Restoring a backup must merge the archived vault into this Mac's vault
    /// without ever writing the recovered ciphertext — let alone its contents
    /// — to a temporary file, so the decode has to work on bytes rather than a
    /// path. `load` is the same code reading from `fileURL`.
    /// WHY: .project-docs/decisions/2026-10-19-config-backup.md
    static func decode(envelope envelopeData: Data, using key: SymmetricKey) throws -> CaseVaultPayload {
        let envelope: CaseVaultEnvelope
        do {
            envelope = try JSONDecoder.caseVault.decode(CaseVaultEnvelope.self, from: envelopeData)
        } catch {
            throw CaseVaultStoreError.invalidEnvelope
        }
        guard envelope.version == Self.envelopeVersion, envelope.algorithm == Self.algorithm else {
            throw CaseVaultStoreError.unsupportedEnvelope
        }
        guard
            let nonceData = Data(base64Encoded: envelope.nonce),
            let ciphertext = Data(base64Encoded: envelope.ciphertext),
            let tag = Data(base64Encoded: envelope.tag)
        else {
            throw CaseVaultStoreError.invalidEnvelope
        }
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag: tag
            )
        } catch {
            throw CaseVaultStoreError.invalidEnvelope
        }
        let data = try AES.GCM.open(sealedBox, using: key, authenticating: Self.staticAssociatedData())
        return try CaseVaultMigration.decodePayload(data)
    }

    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws {
        let parent = fileURL.deletingLastPathComponent()
        try ensurePrivateParentDirectory(parent)

        let payloadData = try JSONEncoder.caseVault.encode(payload)
        let sealed = try AES.GCM.seal(payloadData, using: key, authenticating: associatedData())
        let nonceData = sealed.nonce.withUnsafeBytes { Data($0) }
        let envelope = CaseVaultEnvelope(
            version: Self.envelopeVersion,
            algorithm: Self.algorithm,
            nonce: nonceData.base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
        let envelopeData = try JSONEncoder.caseVault.encode(envelope)
        // A failed backup must not block the save itself.
        try? keepBackupOfCurrentVault()
        try envelopeData.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }

    /// Move a vault that can't be decrypted with the current key (rotated or
    /// lost key, another build's key, corrupt file) aside, so the next unlock
    /// starts a fresh empty vault while the old file stays next to it in case
    /// its key turns up again. No-op if the file is already absent.
    func reset() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8)
        let aside = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).unreadable-\(stamp)-\(suffix)")
        try fileManager.moveItem(at: fileURL, to: aside)
    }

    private func keepBackupOfCurrentVault() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        if fileManager.fileExists(atPath: backupFileURL.path) {
            try fileManager.removeItem(at: backupFileURL)
        }
        try fileManager.copyItem(at: fileURL, to: backupFileURL)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: backupFileURL.path)
    }

    private func associatedData() -> Data { Self.staticAssociatedData() }

    private static func staticAssociatedData() -> Data {
        Data("com.rootwise.sidekey.case-vault.v1".utf8)
    }

    private func ensurePrivateParentDirectory(_ parent: URL) throws {
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: parent.path)
    }
}

extension JSONEncoder {
    static var caseVault: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var caseVault: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let bitPattern = try container.decode(UInt64.self)
            return Date(timeIntervalSinceReferenceDate: TimeInterval(bitPattern: bitPattern))
        }
        return decoder
    }
}
