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
        let data = try AES.GCM.open(sealedBox, using: key, authenticating: associatedData())
        let payload = try JSONDecoder.caseVault.decode(CaseVaultPayload.self, from: data)
        if payload.schemaVersion > CaseVaultPayload.currentSchemaVersion {
            // The vault was written by a newer build of the app. Decryption
            // succeeded — the data is intact — but this version can't interpret
            // the newer schema. Surface needsNewerApp so the UI directs the user
            // to update; crucially, this must NOT be treated as undecryptable or
            // offer a destructive Reset.
            throw CaseVaultStoreError.needsNewerApp
        }
        guard payload.schemaVersion == CaseVaultPayload.currentSchemaVersion else {
            // schemaVersion < current: an older format we no longer understand.
            throw CaseVaultStoreError.unsupportedEnvelope
        }
        return payload
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

    private func associatedData() -> Data {
        Data("com.rootwise.sidekey.case-vault.v1".utf8)
    }

    private func ensurePrivateParentDirectory(_ parent: URL) throws {
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: parent.path)
    }
}

private extension JSONEncoder {
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

private extension JSONDecoder {
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
