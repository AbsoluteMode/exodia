import CryptoKit
import Foundation

/// Complete user-artifact backup: one streaming, authenticated `.exodiabackup`
/// file. Everything that identifies content — the manifest, the private file
/// names, the sizes and the digests — lives inside the encryption. Only a
/// 32-byte header (magic, format version, frame size, random salt) is clear,
/// and it is authenticated by every frame.
///
/// The frame chain is what makes truncation and reordering detectable: each
/// frame's nonce and additional data carry its index and whether it is the
/// final frame, so a dropped tail, a duplicated frame or two swapped frames
/// all fail authentication instead of decoding into a shorter "valid" archive.
///
/// WHY: .project-docs/decisions/2026-10-19-config-backup.md
enum ArtifactBackupError: Error, LocalizedError, Equatable {
    case notAnArchive
    case needsNewerApp
    case cannotUnlock
    case damaged
    case truncated
    case tooLarge
    case unsafeContent
    case readFailed
    case writeFailed
    case busy
    case nothingSelected
    case missingSection
    case requiredFileMissing(String)
    case caseUnreadable
    case keyUnavailable
    case restoreFailed
    case restoreInterrupted
    case contentChanged(String)
    case incompleteArchive(String)
    case invalidContent(String)
    case restoreNeedsRecovery(String)
    case applyInProgress

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "This file is not a Whytap backup. Choose a .exodiabackup file."
        case .needsNewerApp:
            return "This backup was written by a newer version of Whytap. Update Whytap first; nothing on this Mac has changed."
        case .cannotUnlock:
            return "This recovery key could not open the backup. Check the key, or choose another backup."
        case .damaged:
            return "This backup is damaged or incomplete. Choose another version."
        case .truncated:
            return "This backup is missing its end. The upload or copy did not finish; choose another version."
        case .tooLarge:
            return "This backup is larger than Whytap can process."
        case .unsafeContent:
            return "This backup contains a file path Whytap will not write. Nothing has been restored."
        case .readFailed:
            return "Whytap could not read all the files it needs. Check the disk and try again."
        case .writeFailed:
            return "The backup could not be written. Check the folder and available space, then try again."
        case .busy:
            return "A backup is already running. Wait for it to finish."
        case .nothingSelected:
            return "Choose at least one kind of data."
        case .missingSection:
            return "This backup does not contain the data you selected."
        case .requiredFileMissing(let name):
            return "A file this backup needs is missing: \(name). Nothing has been backed up."
        case .caseUnreadable:
            return "Whytap cannot read this Mac's Case vault, so it was not included. Unlock Case, then back up again."
        case .keyUnavailable:
            return "Whytap could not access its backup key. Unlock your Mac and try again."
        case .restoreFailed:
            return "The restore did not finish. Your previous data has been kept."
        case .restoreInterrupted:
            return "The last restore was interrupted, so your previous data was put back. Try restoring again."
        case .contentChanged(let name):
            return "\(name) changed while Whytap was backing it up. Nothing has been backed up; try again when recording and processing have finished."
        case .incompleteArchive(let detail):
            return "This backup is missing data it says it contains (\(detail)). Nothing has been restored."
        case .invalidContent(let detail):
            return "This backup contains data Whytap cannot read (\(detail)). Nothing has been restored."
        case .restoreNeedsRecovery(let path):
            return "Whytap could not finish putting your previous data back. Every original file, the backup copy and the restore record are preserved at \(path). Nothing was deleted; open Whytap again or recover those files before retrying."
        case .applyInProgress:
            return "A restore is already being applied. Open Whytap again to let it finish or roll back."
        }
    }
}

// MARK: - Manifest

/// Logical, section-scoped entry paths. The restore side maps every path
/// explicitly; anything it does not recognise is refused rather than written.
struct ArtifactBackupManifest: Codable, Equatable, Sendable {
    static let currentSchema = 2
    static let maxBytes = 16 * 1024 * 1024
    static let maxEntries = 200_000
    static let maxEntryBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let maxTotalBytes: Int64 = 64 * 1024 * 1024 * 1024
    /// Entries restored through memory (secrets and configurations that are
    /// rewritten before they land on disk) never exceed this.
    static let maxInlineBytes: Int64 = 8 * 1024 * 1024

    struct Entry: Codable, Equatable, Sendable {
        var path: String
        var section: ArtifactBackupSection
        var bytes: Int64
        var sha256: String
    }

    var schema: Int = ArtifactBackupManifest.currentSchema
    var id: UUID
    var createdAt: Date
    var flavor: String
    var appVersion: String?
    var appBuild: String?
    var sections: [ArtifactBackupSection]
    var entries: [Entry]
    var contentBytes: Int64
    var warnings: [String]

    /// Only the schema is read before anything else, so a future archive is
    /// rejected with "update Whytap" instead of a decoding error.
    private struct SchemaProbe: Decodable { let schema: Int }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maxBytes else { throw ArtifactBackupError.tooLarge }
        let probe: SchemaProbe
        do { probe = try JSONDecoder.artifactBackup.decode(SchemaProbe.self, from: data) }
        catch { throw ArtifactBackupError.damaged }
        guard probe.schema <= currentSchema else { throw ArtifactBackupError.needsNewerApp }
        guard (1...currentSchema).contains(probe.schema) else { throw ArtifactBackupError.damaged }
        let manifest: Self
        do { manifest = try JSONDecoder.artifactBackup.decode(Self.self, from: data) }
        catch { throw ArtifactBackupError.damaged }
        try manifest.validate()
        return manifest
    }

    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder.artifactBackup.encode(self)
        guard data.count <= Self.maxBytes else { throw ArtifactBackupError.tooLarge }
        return data
    }

    func validate() throws {
        guard schema >= 2 || !sections.contains(.planner) else { throw ArtifactBackupError.damaged }
        guard entries.count <= Self.maxEntries, !sections.isEmpty,
              Set(sections).count == sections.count else { throw ArtifactBackupError.damaged }
        var total: Int64 = 0
        var seen = Set<String>()
        for entry in entries {
            guard (entry.section == .planner) == entry.path.hasPrefix("planner/") else {
                throw ArtifactBackupError.unsafeContent
            }
            try ArtifactBackupPath.validate(entry.path)
            guard seen.insert(entry.path).inserted else { throw ArtifactBackupError.damaged }
            guard sections.contains(entry.section) else { throw ArtifactBackupError.damaged }
            guard entry.bytes >= 0, entry.bytes <= Self.maxEntryBytes,
                  entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else { throw ArtifactBackupError.damaged }
            total += entry.bytes
            guard total <= Self.maxTotalBytes else { throw ArtifactBackupError.tooLarge }
        }
        guard total == contentBytes else { throw ArtifactBackupError.damaged }
        guard warnings.count <= 64, warnings.allSatisfy({ $0.utf8.count <= 400 }) else {
            throw ArtifactBackupError.damaged
        }
    }

    var summary: ArtifactBackupSummary {
        ArtifactBackupSummary(id: id, createdAt: createdAt, totalBytes: contentBytes,
                              fileCount: entries.count, sections: Set(sections))
    }
}

/// Entry paths are the only names the restore side is allowed to act on, so
/// they are checked before anything is written: no absolute paths, no `..`,
/// no hidden or empty components, no separators smuggled through a component.
enum ArtifactBackupPath {
    static let maxLength = 512
    static let maxComponents = 8
    static let roots: Set<String> = ["settings", "credentials", "case", "meetings", "history", "workspace", "planner"]

    static func validate(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= maxLength, !path.contains("\0"),
              !path.contains("\\"), !path.hasPrefix("/"), !path.contains("//")
        else { throw ArtifactBackupError.unsafeContent }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (2...maxComponents).contains(components.count), roots.contains(components[0]) else {
            throw ArtifactBackupError.unsafeContent
        }
        for component in components {
            guard !component.isEmpty, component != ".", component != "..",
                  !component.hasPrefix("."), component.utf8.count <= 120,
                  component.unicodeScalars.allSatisfy({ scalar in
                      scalar.value > 0x20 && scalar.value < 0x7F && scalar != ":"
                  })
            else { throw ArtifactBackupError.unsafeContent }
        }
    }
}

extension JSONEncoder {
    static var artifactBackup: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var artifactBackup: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Framing

struct ArtifactArchiveHeader: Equatable, Sendable {
    static let magic = Array("EXOBKUP1".utf8)
    static let byteCount = 32
    static let formatVersion: UInt16 = 1
    static let minChunkSize = 16 * 1024
    static let maxChunkSize = 8 * 1024 * 1024

    let chunkSize: Int
    let salt: Data
    let encoded: Data

    init(chunkSize: Int) throws {
        guard (Self.minChunkSize...Self.maxChunkSize).contains(chunkSize) else {
            throw ArtifactBackupError.writeFailed
        }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ArtifactBackupError.keyUnavailable }
        self.chunkSize = chunkSize
        self.salt = salt
        var bytes = Data(Self.magic)
        bytes.append(contentsOf: Self.bigEndian16(Self.formatVersion))
        bytes.append(contentsOf: [0, 0])
        bytes.append(contentsOf: Self.bigEndian32(UInt32(chunkSize)))
        bytes.append(salt)
        self.encoded = bytes
    }

    init(parsing data: Data) throws {
        guard data.count == Self.byteCount else { throw ArtifactBackupError.notAnArchive }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<8]) == Self.magic else { throw ArtifactBackupError.notAnArchive }
        let version = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard version != 0 else { throw ArtifactBackupError.notAnArchive }
        guard version <= Self.formatVersion else { throw ArtifactBackupError.needsNewerApp }
        let size = bytes[12..<16].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard (Self.minChunkSize...Self.maxChunkSize).contains(Int(size)) else {
            throw ArtifactBackupError.damaged
        }
        self.chunkSize = Int(size)
        self.salt = Data(bytes[16..<32])
        self.encoded = data
    }

    static func bigEndian16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

    static func bigEndian32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func bigEndian64(_ value: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8(value >> (8 * UInt64($0)) & 0xFF) }
    }
}

/// Per-frame AES-GCM with a key and nonce prefix derived from the supplied
/// 32-byte archive key. The archive key itself is never used directly, and
/// each archive gets its own salt, so two archives of the same data share no
/// key stream.
struct ArtifactArchiveCipher: Sendable {
    private let key: SymmetricKey
    private let noncePrefix: [UInt8]
    private let header: Data

    init(archiveKey: Data, header: ArtifactArchiveHeader) throws {
        guard archiveKey.count == 32 else { throw ArtifactBackupError.keyUnavailable }
        let material = SymmetricKey(data: archiveKey)
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: header.salt,
                                     info: Data("exodia.artifact-backup.v1.frame-key".utf8),
                                     outputByteCount: 32)
        let prefix = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: header.salt,
                                            info: Data("exodia.artifact-backup.v1.nonce".utf8),
                                            outputByteCount: 4)
        noncePrefix = prefix.withUnsafeBytes { [UInt8]($0) }
        self.header = header.encoded
    }

    func seal(_ plaintext: Data, counter: UInt64, isFinal: Bool) throws -> Data {
        do {
            let box = try AES.GCM.seal(plaintext, using: key,
                                       nonce: try nonce(counter),
                                       authenticating: associatedData(counter, isFinal))
            return box.ciphertext + box.tag
        } catch { throw ArtifactBackupError.writeFailed }
    }

    func open(_ frame: Data, counter: UInt64, isFinal: Bool) throws -> Data {
        guard frame.count >= 16 else { throw ArtifactBackupError.damaged }
        let split = frame.index(frame.endIndex, offsetBy: -16)
        do {
            let box = try AES.GCM.SealedBox(nonce: try nonce(counter),
                                            ciphertext: frame[frame.startIndex..<split],
                                            tag: frame[split..<frame.endIndex])
            return try AES.GCM.open(box, using: key, authenticating: associatedData(counter, isFinal))
        } catch { throw ArtifactBackupError.cannotUnlock }
    }

    private func nonce(_ counter: UInt64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: Data(noncePrefix + ArtifactArchiveHeader.bigEndian64(counter)))
    }

    private func associatedData(_ counter: UInt64, _ isFinal: Bool) -> Data {
        var data = header
        data.append(contentsOf: ArtifactArchiveHeader.bigEndian64(counter))
        data.append(isFinal ? 1 : 0)
        return data
    }
}

/// Bounded-memory writer: plaintext is buffered only up to one frame, so a
/// multi-gigabyte recording never has to fit in RAM.
final class ArtifactArchiveWriter {
    static let defaultChunkSize = 1 << 20

    private let url: URL
    private let handle: FileHandle
    private let cipher: ArtifactArchiveCipher
    private let header: ArtifactArchiveHeader
    private var buffer: Data
    private var counter: UInt64 = 0
    private var closed = false

    init(url: URL, archiveKey: Data, chunkSize: Int = ArtifactArchiveWriter.defaultChunkSize) throws {
        self.url = url
        header = try ArtifactArchiveHeader(chunkSize: chunkSize)
        cipher = try ArtifactArchiveCipher(archiveKey: archiveKey, header: header)
        buffer = Data()
        buffer.reserveCapacity(chunkSize)
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { try? manager.removeItem(at: url) }
        guard manager.createFile(atPath: url.path, contents: nil,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw ArtifactBackupError.writeFailed
        }
        do { handle = try FileHandle(forWritingTo: url) } catch { throw ArtifactBackupError.writeFailed }
        do { try handle.write(contentsOf: header.encoded) } catch { throw ArtifactBackupError.writeFailed }
    }

    func append(_ data: Data) throws {
        guard !closed else { throw ArtifactBackupError.writeFailed }
        buffer.append(data)
        while buffer.count >= header.chunkSize {
            let chunk = buffer.prefix(header.chunkSize)
            buffer.removeFirst(header.chunkSize)
            try emit(Data(chunk), isFinal: false)
        }
    }

    func append(contentsOf file: URL) throws {
        guard let reader = try? FileHandle(forReadingFrom: file) else {
            throw ArtifactBackupError.readFailed
        }
        defer { try? reader.close() }
        while true {
            let block: Data?
            do { block = try reader.read(upToCount: header.chunkSize) }
            catch { throw ArtifactBackupError.readFailed }
            guard let block, !block.isEmpty else { break }
            try append(block)
        }
    }

    /// Emits the remaining plaintext as the authenticated final frame. Without
    /// it a reader sees a truncated archive, which is exactly what an
    /// interrupted upload or a half-written file must look like.
    func finish() throws {
        guard !closed else { return }
        let tail = buffer
        buffer = Data()
        try emit(tail, isFinal: true)
        do { try handle.synchronize(); try handle.close() } catch { throw ArtifactBackupError.writeFailed }
        closed = true
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    private func emit(_ plaintext: Data, isFinal: Bool) throws {
        let frame = try cipher.seal(plaintext, counter: counter, isFinal: isFinal)
        var record = Data(ArtifactArchiveHeader.bigEndian32(UInt32(frame.count) | (isFinal ? 0x8000_0000 : 0)))
        record.append(frame)
        do { try handle.write(contentsOf: record) } catch { throw ArtifactBackupError.writeFailed }
        counter &+= 1
    }
}

/// Bounded-memory reader over the same framing. `verifyEnd()` is the
/// truncation and trailing-data check; callers must call it after consuming
/// everything the manifest describes.
final class ArtifactArchiveReader {
    let header: ArtifactArchiveHeader

    private let handle: FileHandle
    private let cipher: ArtifactArchiveCipher
    private var buffer = Data()
    private var sawFinal = false
    private var counter: UInt64 = 0

    init(url: URL, archiveKey: Data) throws {
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ArtifactBackupError.readFailed }
        let head: Data
        do { head = (try handle.read(upToCount: ArtifactArchiveHeader.byteCount)) ?? Data() }
        catch { throw ArtifactBackupError.readFailed }
        do {
            header = try ArtifactArchiveHeader(parsing: head)
            cipher = try ArtifactArchiveCipher(archiveKey: archiveKey, header: header)
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit { try? handle.close() }

    func close() { try? handle.close() }

    func read(exactly count: Int) throws -> Data {
        guard count >= 0 else { throw ArtifactBackupError.damaged }
        while buffer.count < count {
            guard try fill() else { throw ArtifactBackupError.truncated }
        }
        let value = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return value
    }

    /// Streams `count` plaintext bytes to `sink` without holding more than one
    /// frame in memory.
    func forward(_ count: Int64, into sink: (Data) throws -> Void) throws {
        var remaining = count
        while remaining > 0 {
            if buffer.isEmpty {
                guard try fill() else { throw ArtifactBackupError.truncated }
                continue
            }
            let take = Int(min(remaining, Int64(buffer.count)))
            let block = Data(buffer.prefix(take))
            buffer.removeFirst(take)
            try sink(block)
            remaining -= Int64(take)
        }
    }

    func verifyEnd() throws {
        while try fill() { }
        guard sawFinal, buffer.isEmpty else { throw ArtifactBackupError.damaged }
        let trailing: Data?
        do { trailing = try handle.read(upToCount: 1) } catch { throw ArtifactBackupError.readFailed }
        guard (trailing ?? Data()).isEmpty else { throw ArtifactBackupError.damaged }
    }

    @discardableResult
    private func fill() throws -> Bool {
        guard !sawFinal else { return false }
        let lengthData: Data
        do { lengthData = (try handle.read(upToCount: 4)) ?? Data() }
        catch { throw ArtifactBackupError.readFailed }
        guard lengthData.count == 4 else { throw ArtifactBackupError.truncated }
        let field = [UInt8](lengthData).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let isFinal = field & 0x8000_0000 != 0
        let length = Int(field & 0x7FFF_FFFF)
        guard length >= 16, length <= header.chunkSize + 16 else { throw ArtifactBackupError.damaged }
        let frame: Data
        do { frame = (try handle.read(upToCount: length)) ?? Data() }
        catch { throw ArtifactBackupError.readFailed }
        guard frame.count == length else { throw ArtifactBackupError.truncated }
        buffer.append(try cipher.open(frame, counter: counter, isFinal: isFinal))
        counter &+= 1
        sawFinal = isFinal
        return true
    }
}

// MARK: - Digests

enum ArtifactBackupDigest {
    static let blockSize = 1 << 20

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func of(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// Streaming digest: the file is never loaded as a whole, so hashing a
    /// large staged recording costs one frame of memory.
    static func ofFile(_ url: URL) throws -> (digest: String, bytes: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ArtifactBackupError.readFailed
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let block: Data?
            do { block = try handle.read(upToCount: blockSize) } catch { throw ArtifactBackupError.readFailed }
            guard let block, !block.isEmpty else { break }
            hasher.update(data: block)
            total += Int64(block.count)
        }
        return (hex(hasher.finalize()), total)
    }
}
