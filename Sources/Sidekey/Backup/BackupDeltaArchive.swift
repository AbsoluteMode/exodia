import CryptoKit
import Foundation

/// Delta transport for complete `.exodiabackup` archives.
///
/// A full local archive stays the portable artifact: the format, the framing
/// and the manifest are unchanged, and the public restore path only ever sees
/// a standalone full archive. What travels to a remote destination may instead
/// be a *delta*: an ordinary archive of the same format that carries only the
/// entries whose bytes differ from an already checked prior snapshot in the
/// same destination, plus one reserved, authenticated metadata entry naming
/// that parent and describing the snapshot in full.
///
/// This type is only the format transformer plus bounded reconstruction.
/// Parent retention, chain length policy, periodic compaction, downloading
/// every dependency, the local catalog, the transport and the UI live with the
/// caller. Nothing here starts a job, touches the Keychain, reads user data or
/// makes a network request.
///
/// Material limits (none of them new crypto):
/// - the archive key, framing, nonce derivation and per-frame authentication
///   are exactly `ArtifactArchiveHeader`/`ArtifactArchiveCipher`; a delta is
///   sealed under its own fresh header and salt, so no nonce is ever reused;
/// - a chain is at most `BackupDeltaFormat.maxChainLength` archives
///   (32 deltas and one standalone full), newest first;
/// - reconstruction streams every file directly from whichever authenticated
///   ancestor owns its bytes into one new encrypted output: no intermediate
///   full archive, no plaintext temporary file, one decrypted frame per
///   ancestor held in memory;
/// - secrets (provider keys, the Case vault key, private names) never leave
///   authenticated encryption; they pass through memory only.
///
/// WHY: .project-docs/decisions/2026-10-19-config-backup.md
enum BackupDeltaFormat {
    /// Reserved logical entry. It is a delta marker, never an ordinary user
    /// entry: a snapshot manifest that contains this path is refused.
    static let metadataPath = "settings/backup-delta-v1.json"
    static let metadataSection = ArtifactBackupSection.settings
    static let currentVersion = 1
    /// 32 deltas plus the standalone full archive they ultimately depend on.
    static let maxDeltaDepth = 32
    static let maxChainLength = maxDeltaDepth + 1
    /// The metadata entry carries the whole snapshot manifest. It is bounded
    /// like any other in-memory payload; beyond this a delta is not worth it.
    static let maxMetadataBytes: Int64 = ArtifactBackupManifest.maxInlineBytes
    /// Frame index ceiling: at the 1 MiB default chunk this is a terabyte of
    /// archive, far above the 64 GiB content limit, and keeps a hostile
    /// length field from making us allocate an unbounded index.
    static let maxFrames = 1 << 20
    /// Below this saving a delta is not worth its dependency: send the full.
    static let minimumSaving = 0.20

    /// `currentManifest` is the authenticated description of the snapshot the
    /// delta represents — exactly the manifest the reconstructed full archive
    /// must carry, including its id, date, sections, warnings, paths, sizes
    /// and digests. Deletions need no marker: a removed entry is simply
    /// absent from it.
    struct Metadata: Codable, Equatable, Sendable {
        var version: Int = BackupDeltaFormat.currentVersion
        var baseID: UUID
        var currentManifest: ArtifactBackupManifest
    }

    /// Only the versions are read before anything else, so a future delta is
    /// rejected with "update Whytap" instead of a decoding error.
    private struct Probe: Decodable {
        struct ManifestProbe: Decodable { let schema: Int }
        let version: Int
        let currentManifest: ManifestProbe
    }

    static func decodeMetadata(_ data: Data) throws -> Metadata {
        guard Int64(data.count) <= maxMetadataBytes else { throw ArtifactBackupError.tooLarge }
        let probe: Probe
        do { probe = try JSONDecoder.artifactBackup.decode(Probe.self, from: data) }
        catch { throw ArtifactBackupError.damaged }
        guard probe.version <= currentVersion,
              probe.currentManifest.schema <= ArtifactBackupManifest.currentSchema else {
            throw ArtifactBackupError.needsNewerApp
        }
        guard probe.version == currentVersion,
              (1...ArtifactBackupManifest.currentSchema).contains(probe.currentManifest.schema) else {
            throw ArtifactBackupError.damaged
        }
        let metadata: Metadata
        do { metadata = try JSONDecoder.artifactBackup.decode(Metadata.self, from: data) }
        catch { throw ArtifactBackupError.damaged }
        try metadata.currentManifest.validate()
        // The reserved entry describes the delta; a snapshot must never claim
        // to contain it as one of the user's own files.
        guard !metadata.currentManifest.entries.contains(where: { $0.path == metadataPath }) else {
            throw ArtifactBackupError.damaged
        }
        return metadata
    }

    static func encodeMetadata(_ metadata: Metadata) throws -> Data {
        try metadata.currentManifest.validate()
        let data = try JSONEncoder.artifactBackup.encode(metadata)
        guard Int64(data.count) <= maxMetadataBytes else { throw ArtifactBackupError.tooLarge }
        return data
    }
}

// MARK: - Indexed frame reader

/// Random access over the existing archive framing, without inventing any
/// crypto: the frame records are scanned for their lengths only (AES-GCM
/// ciphertext is the length of its plaintext plus a 16-byte tag, so plaintext
/// offsets are known without decrypting anything), and a needed frame is then
/// seeked to and opened with `ArtifactArchiveCipher` under its original
/// counter, final flag and header.
///
/// The scan is also the structural check: a missing final frame is a
/// truncation, bytes after it are trailing data, and an out-of-range length
/// field is damage — all refused before a single byte is used.
final class BackupDeltaFrameReader {
    private struct Frame {
        let fileOffset: UInt64
        let length: Int
        let plaintextStart: Int64
        let plaintextCount: Int
    }

    let header: ArtifactArchiveHeader
    /// Total plaintext the archive carries, framing excluded.
    let plaintextBytes: Int64

    private let handle: FileHandle
    private let cipher: ArtifactArchiveCipher
    private let frames: [Frame]
    private var cachedFrame = -1
    private var cachedPlaintext = Data()
    private var closed = false

    init(url: URL, archiveKey: Data) throws {
        try BackupDeltaArchive.requireRegularFile(url)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ArtifactBackupError.readFailed
        }
        self.handle = handle
        do {
            let fileSize: UInt64
            do { fileSize = try handle.seekToEnd(); try handle.seek(toOffset: 0) }
            catch { throw ArtifactBackupError.readFailed }
            let head: Data
            do { head = (try handle.read(upToCount: ArtifactArchiveHeader.byteCount)) ?? Data() }
            catch { throw ArtifactBackupError.readFailed }
            header = try ArtifactArchiveHeader(parsing: head)
            cipher = try ArtifactArchiveCipher(archiveKey: archiveKey, header: header)

            var scanned: [Frame] = []
            var position = UInt64(ArtifactArchiveHeader.byteCount)
            var plaintextTotal: Int64 = 0
            var sawFinal = false
            while position < fileSize {
                guard scanned.count < BackupDeltaFormat.maxFrames else {
                    throw ArtifactBackupError.tooLarge
                }
                let lengthData: Data
                do {
                    try handle.seek(toOffset: position)
                    lengthData = (try handle.read(upToCount: 4)) ?? Data()
                } catch { throw ArtifactBackupError.readFailed }
                guard lengthData.count == 4 else { throw ArtifactBackupError.truncated }
                let field = [UInt8](lengthData).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                let isFinal = field & 0x8000_0000 != 0
                let length = Int(field & 0x7FFF_FFFF)
                guard length >= 16, length <= header.chunkSize + 16 else {
                    throw ArtifactBackupError.damaged
                }
                let next = position + 4 + UInt64(length)
                guard next <= fileSize else { throw ArtifactBackupError.truncated }
                scanned.append(Frame(fileOffset: position + 4, length: length,
                                     plaintextStart: plaintextTotal, plaintextCount: length - 16))
                plaintextTotal += Int64(length - 16)
                position = next
                if isFinal { sawFinal = true; break }
            }
            // Exactly the same contract as `ArtifactArchiveReader.verifyEnd`:
            // the final frame must exist and must end the file.
            guard sawFinal else { throw ArtifactBackupError.truncated }
            guard position == fileSize else { throw ArtifactBackupError.damaged }
            frames = scanned
            plaintextBytes = plaintextTotal
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit { if !closed { try? handle.close() } }

    func close() {
        guard !closed else { return }
        closed = true
        cachedFrame = -1
        cachedPlaintext = Data()
        try? handle.close()
    }

    /// Streams `count` plaintext bytes from `start` without holding more than
    /// one decrypted frame.
    func copy(from start: Int64, count: Int64, into sink: (Data) throws -> Void) throws {
        guard !closed else { throw ArtifactBackupError.readFailed }
        guard start >= 0, count >= 0, start <= plaintextBytes,
              plaintextBytes - start >= count else { throw ArtifactBackupError.damaged }
        var position = start
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let index = try frame(containing: position)
            let plaintext = try self.plaintext(at: index)
            let inner = Int(position - frames[index].plaintextStart)
            guard inner >= 0, inner < plaintext.count else { throw ArtifactBackupError.damaged }
            let take = Int(min(remaining, Int64(plaintext.count - inner)))
            let lower = plaintext.index(plaintext.startIndex, offsetBy: inner)
            let upper = plaintext.index(lower, offsetBy: take)
            try sink(Data(plaintext[lower..<upper]))
            position += Int64(take)
            remaining -= Int64(take)
        }
    }

    /// Bounded read for the small, structural head of an archive (the
    /// length-prefixed manifest and the reserved metadata entry).
    func read(from start: Int64, count: Int) throws -> Data {
        guard count >= 0, count <= ArtifactBackupManifest.maxBytes else {
            throw ArtifactBackupError.tooLarge
        }
        var buffer = Data()
        buffer.reserveCapacity(count)
        try copy(from: start, count: Int64(count)) { buffer.append($0) }
        return buffer
    }

    private func frame(containing position: Int64) throws -> Int {
        var low = 0
        var high = frames.count - 1
        var found = -1
        while low <= high {
            let middle = low + (high - low) / 2
            if frames[middle].plaintextStart <= position {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard found >= 0 else { throw ArtifactBackupError.damaged }
        return found
    }

    private func plaintext(at index: Int) throws -> Data {
        if cachedFrame == index { return cachedPlaintext }
        let frame = frames[index]
        let ciphertext: Data
        do {
            try handle.seek(toOffset: frame.fileOffset)
            ciphertext = (try handle.read(upToCount: frame.length)) ?? Data()
        } catch { throw ArtifactBackupError.readFailed }
        guard ciphertext.count == frame.length else { throw ArtifactBackupError.truncated }
        let plaintext = try cipher.open(ciphertext, counter: UInt64(index),
                                        isFinal: index == frames.count - 1)
        guard plaintext.count == frame.plaintextCount else { throw ArtifactBackupError.damaged }
        cachedFrame = index
        cachedPlaintext = plaintext
        return plaintext
    }
}

// MARK: - Delta archive

actor BackupDeltaArchive {
    /// What the caller should upload. `baseID` is the authenticated snapshot
    /// UUID this file depends on; `nil` means the file is a standalone full
    /// archive and `file` may be the full input itself.
    struct Prepared: Equatable, Sendable {
        let file: URL
        let baseID: UUID?
    }

    /// One authenticated archive in a chain, with the offsets of the bytes it
    /// actually carries.
    private struct Link {
        let url: URL
        /// The snapshot this archive represents.
        let snapshotID: UUID
        /// The parent snapshot a delta depends on; `nil` for a standalone full.
        let baseID: UUID?
        /// The complete description of `snapshotID`: a delta's authenticated
        /// `currentManifest`, or a full archive's own manifest.
        let effective: ArtifactBackupManifest
        /// The entries whose bytes this archive carries (metadata included).
        let carried: [String: ArtifactBackupManifest.Entry]
        let offsets: [String: Int64]
        let reader: BackupDeltaFrameReader
    }

    private struct Plan {
        let manifest: ArtifactBackupManifest
        let current: ArtifactBackupManifest
        let metadata: Data
        let changed: Set<String>
        let baseID: UUID
        let plaintextBytes: Int64
    }

    private enum FileKind { case missing, regular, directory, symlink, other }

    init() {}

    // MARK: Prepare

    /// Validates the current full archive and, when a usable base is given and
    /// a delta is actually worth it, writes a delta of the same format to
    /// `output`.
    ///
    /// A bad current archive fails. An unavailable, unreadable, wrong-key or
    /// newer-format base is not a failure: the already validated full archive
    /// is still a correct upload, so `prepare` falls back to it. An input
    /// symlink is refused outright rather than followed.
    func prepare(full: URL, base: URL?, output: URL, key: Data) throws -> Prepared {
        try Task.checkCancellation()
        guard key.count == 32 else { throw ArtifactBackupError.keyUnavailable }
        try Self.requireRegularFile(full)
        let current = try ArtifactRestoreTransaction.validateArchive(at: full, key: key)
        guard !current.entries.contains(where: { $0.path == BackupDeltaFormat.metadataPath }) else {
            // The caller's "full" input is itself a delta: refuse rather than
            // stack a delta on a dependent file.
            throw ArtifactBackupError.invalidContent("backup delta")
        }
        let standalone = Prepared(file: full, baseID: nil)
        guard let base else { return standalone }
        switch Self.kind(of: base) {
        case .regular: break
        case .missing: return standalone
        case .symlink, .directory, .other: throw ArtifactBackupError.unsafeContent
        }
        guard !Self.isSamePath(base, full) else { return standalone }

        let parent: Link
        do { parent = try Self.readLink(base, key: key, verifyPayloads: false) }
        catch { return standalone }
        defer { parent.reader.close() }
        guard parent.snapshotID != current.id else { return standalone }
        guard let plan = Self.plan(current: current, parent: parent) else { return standalone }

        let fullSize = Self.fileSize(full)
        guard fullSize > 0, Double(Self.estimatedSize(plaintext: plan.plaintextBytes))
                <= Double(fullSize) * (1 - BackupDeltaFormat.minimumSaving) else {
            return standalone
        }
        try write(plan: plan, from: full, to: output, key: key)
        // The estimate is framing arithmetic; the file on disk is the actual
        // transfer. If it did not save what it promised, send the full.
        guard Double(Self.fileSize(output)) <= Double(fullSize) * (1 - BackupDeltaFormat.minimumSaving) else {
            try? FileManager.default.removeItem(at: output)
            return standalone
        }
        return Prepared(file: output, baseID: plan.baseID)
    }

    // MARK: Base identity

    /// `nil` for a normal standalone full archive. For a delta the metadata
    /// and the container are fully validated — framing, manifest, the
    /// reserved entry's digest, the metadata schema, the snapshot identity and
    /// every carried entry's digest — before its parent UUID is returned.
    func baseID(in archive: URL, key: Data) throws -> UUID? {
        try Task.checkCancellation()
        guard key.count == 32 else { throw ArtifactBackupError.cannotUnlock }
        let link = try Self.readLink(archive, key: key, verifyPayloads: true)
        link.reader.close()
        return link.baseID
    }

    // MARK: Reconstruct

    /// Produces one standalone portable full archive for the newest snapshot
    /// in `chain` (newest first, ending with a standalone full archive), so
    /// the existing engine can inspect and stage it unchanged.
    ///
    /// Every ancestor is read once; each file is streamed directly from
    /// whichever authenticated ancestor owns its bytes into the new encrypted
    /// output. No intermediate full archive is ever materialised, and no
    /// plaintext — least of all a provider key or the Case key — is written to
    /// a temporary file.
    @discardableResult
    func reconstruct(chain: [URL], output: URL, key: Data) throws -> ArtifactBackupSummary {
        try Task.checkCancellation()
        guard key.count == 32 else { throw ArtifactBackupError.cannotUnlock }
        guard !chain.isEmpty else { throw ArtifactBackupError.incompleteArchive("backup") }
        guard chain.count <= BackupDeltaFormat.maxChainLength else { throw ArtifactBackupError.tooLarge }
        for url in chain { try Self.requireRegularFile(url) }
        var seen = Set<String>()
        for url in chain {
            guard seen.insert(Self.identity(of: url)).inserted else { throw ArtifactBackupError.damaged }
            guard !Self.isSamePath(url, output) else { throw ArtifactBackupError.writeFailed }
        }
        try Self.prepareOutputLocation(output)

        if chain.count == 1 {
            // A single link must already be the standalone full archive; it is
            // validated and copied unchanged.
            let manifest = try ArtifactRestoreTransaction.validateArchive(at: chain[0], key: key)
            guard !manifest.entries.contains(where: { $0.path == BackupDeltaFormat.metadataPath }) else {
                throw ArtifactBackupError.incompleteArchive(BackupDeltaFormat.metadataPath)
            }
            try Self.copyArchive(from: chain[0], to: output)
            return Self.summary(manifest, at: output)
        }

        var links: [Link] = []
        defer { for link in links { link.reader.close() } }
        for url in chain { links.append(try Self.readLink(url, key: key, verifyPayloads: false)) }
        for index in links.indices.dropLast() {
            guard let base = links[index].baseID else { throw ArtifactBackupError.damaged }
            guard base == links[index + 1].snapshotID else {
                throw ArtifactBackupError.incompleteArchive("backup base")
            }
        }
        guard links[links.count - 1].baseID == nil else {
            throw ArtifactBackupError.incompleteArchive("backup base")
        }
        // Distinct snapshots plus strict parent linkage: a cycle cannot be
        // described by a chain whose last link depends on nothing.
        guard Set(links.map(\.snapshotID)).count == links.count else {
            throw ArtifactBackupError.damaged
        }

        let target = links[0].effective
        let effective = links.map { link in
            Dictionary(link.effective.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var owners: [String: Int] = [:]
        for entry in target.entries {
            try Task.checkCancellation()
            var index = 0
            var owner: Int?
            while index < links.count {
                // Every link we walk past must agree about this file; a link
                // that neither carries it nor describes it the same way means
                // the chain does not belong together.
                guard let described = effective[index][entry.path], described == entry else {
                    throw ArtifactBackupError.damaged
                }
                if let held = links[index].carried[entry.path], held == entry {
                    owner = index
                    break
                }
                index += 1
            }
            guard let owner else { throw ArtifactBackupError.incompleteArchive(entry.path) }
            owners[entry.path] = owner
        }

        let writer = try ArtifactArchiveWriter(url: output, archiveKey: key)
        do {
            let manifestData = try target.encoded()
            try writer.append(Data(ArtifactArchiveHeader.bigEndian32(UInt32(manifestData.count))))
            try writer.append(manifestData)
            for entry in target.entries {
                try Task.checkCancellation()
                guard let owner = owners[entry.path], owner < links.count,
                      let offset = links[owner].offsets[entry.path] else {
                    throw ArtifactBackupError.damaged
                }
                var hasher = SHA256()
                try links[owner].reader.copy(from: offset, count: entry.bytes) { block in
                    hasher.update(data: block)
                    try writer.append(block)
                }
                guard ArtifactBackupDigest.hex(hasher.finalize()) == entry.sha256 else {
                    throw ArtifactBackupError.damaged
                }
            }
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
        return Self.summary(target, at: output)
    }

    // MARK: - Planning

    private static func plan(current: ArtifactBackupManifest, parent: Link) -> Plan? {
        var inherited: [String: ArtifactBackupManifest.Entry] = [:]
        for entry in parent.effective.entries { inherited[entry.path] = entry }
        var changed = Set<String>()
        var entries: [ArtifactBackupManifest.Entry] = []
        for entry in current.entries where inherited[entry.path] != entry {
            changed.insert(entry.path)
            entries.append(entry)
        }
        let metadata = BackupDeltaFormat.Metadata(baseID: parent.snapshotID, currentManifest: current)
        guard let metadataData = try? BackupDeltaFormat.encodeMetadata(metadata) else { return nil }
        let reserved = ArtifactBackupManifest.Entry(path: BackupDeltaFormat.metadataPath,
                                                    section: BackupDeltaFormat.metadataSection,
                                                    bytes: Int64(metadataData.count),
                                                    sha256: ArtifactBackupDigest.of(metadataData))
        let all = [reserved] + entries
        let sections = Set(all.map(\.section)).sorted { $0.rawValue < $1.rawValue }
        let manifest = ArtifactBackupManifest(
            id: current.id, createdAt: current.createdAt, flavor: current.flavor,
            appVersion: current.appVersion, appBuild: current.appBuild,
            sections: sections, entries: all,
            contentBytes: all.reduce(Int64(0)) { $0 + $1.bytes }, warnings: [])
        guard let manifestData = try? manifest.encoded() else { return nil }
        return Plan(manifest: manifest, current: current, metadata: metadataData, changed: changed,
                    baseID: parent.snapshotID,
                    plaintextBytes: Int64(4 + manifestData.count) + manifest.contentBytes)
    }

    private func write(plan: Plan, from full: URL, to output: URL, key: Data) throws {
        try Self.prepareOutputLocation(output)
        let writer = try ArtifactArchiveWriter(url: output, archiveKey: key)
        do {
            let manifestData = try plan.manifest.encoded()
            try writer.append(Data(ArtifactArchiveHeader.bigEndian32(UInt32(manifestData.count))))
            try writer.append(manifestData)
            try writer.append(plan.metadata)
            let reader = try ArtifactArchiveReader(url: full, archiveKey: key)
            defer { reader.close() }
            let stored = try Self.readStoredManifest(reader)
            // The full archive was validated moments ago; if its head no
            // longer matches, something replaced the file underneath us.
            guard stored == plan.current else { throw ArtifactBackupError.contentChanged("backup") }
            for entry in stored.entries {
                try Task.checkCancellation()
                var hasher = SHA256()
                if plan.changed.contains(entry.path) {
                    try reader.forward(entry.bytes) { block in
                        hasher.update(data: block)
                        try writer.append(block)
                    }
                } else {
                    try reader.forward(entry.bytes) { hasher.update(data: $0) }
                }
                guard ArtifactBackupDigest.hex(hasher.finalize()) == entry.sha256 else {
                    throw ArtifactBackupError.damaged
                }
            }
            try reader.verifyEnd()
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
    }

    // MARK: - Links

    private static func readLink(_ url: URL, key: Data, verifyPayloads: Bool) throws -> Link {
        let reader = try BackupDeltaFrameReader(url: url, archiveKey: key)
        do {
            let prefix = try reader.read(from: 0, count: 4)
            let length = Int([UInt8](prefix).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length > 0, length <= ArtifactBackupManifest.maxBytes else {
                throw ArtifactBackupError.damaged
            }
            let manifest = try ArtifactBackupManifest.decode(try reader.read(from: 4, count: length))
            var offsets: [String: Int64] = [:]
            var carried: [String: ArtifactBackupManifest.Entry] = [:]
            var offset = Int64(4 + length)
            for entry in manifest.entries {
                offsets[entry.path] = offset
                carried[entry.path] = entry
                offset += entry.bytes
            }
            // The manifest must account for every plaintext byte: no slack
            // between entries, nothing appended after the last one.
            guard offset == reader.plaintextBytes else { throw ArtifactBackupError.damaged }

            guard let reserved = carried[BackupDeltaFormat.metadataPath] else {
                return Link(url: url, snapshotID: manifest.id, baseID: nil, effective: manifest,
                            carried: carried, offsets: offsets, reader: reader)
            }
            guard manifest.entries.first?.path == BackupDeltaFormat.metadataPath,
                  reserved.section == BackupDeltaFormat.metadataSection,
                  reserved.bytes > 0, reserved.bytes <= BackupDeltaFormat.maxMetadataBytes,
                  let reservedOffset = offsets[BackupDeltaFormat.metadataPath] else {
                throw ArtifactBackupError.damaged
            }
            let metadataData = try reader.read(from: reservedOffset, count: Int(reserved.bytes))
            guard ArtifactBackupDigest.of(metadataData) == reserved.sha256 else {
                throw ArtifactBackupError.damaged
            }
            let metadata = try BackupDeltaFormat.decodeMetadata(metadataData)
            let snapshot = metadata.currentManifest
            guard snapshot.id == manifest.id, metadata.baseID != manifest.id else {
                throw ArtifactBackupError.damaged
            }
            var described: [String: ArtifactBackupManifest.Entry] = [:]
            for entry in snapshot.entries { described[entry.path] = entry }
            for entry in manifest.entries where entry.path != BackupDeltaFormat.metadataPath {
                guard described[entry.path] == entry else { throw ArtifactBackupError.damaged }
            }
            if verifyPayloads {
                for entry in manifest.entries {
                    guard let start = offsets[entry.path] else { throw ArtifactBackupError.damaged }
                    var hasher = SHA256()
                    try reader.copy(from: start, count: entry.bytes) { hasher.update(data: $0) }
                    guard ArtifactBackupDigest.hex(hasher.finalize()) == entry.sha256 else {
                        throw ArtifactBackupError.damaged
                    }
                }
            }
            return Link(url: url, snapshotID: manifest.id, baseID: metadata.baseID, effective: snapshot,
                        carried: carried, offsets: offsets, reader: reader)
        } catch {
            reader.close()
            throw error
        }
    }

    /// The archive head exactly as the writer lays it out: a big-endian
    /// 32-bit length followed by the manifest.
    private static func readStoredManifest(_ reader: ArtifactArchiveReader) throws -> ArtifactBackupManifest {
        let prefix = try reader.read(exactly: 4)
        let length = Int([UInt8](prefix).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length > 0, length <= ArtifactBackupManifest.maxBytes else {
            throw ArtifactBackupError.damaged
        }
        return try ArtifactBackupManifest.decode(try reader.read(exactly: length))
    }

    // MARK: - Files

    static func requireRegularFile(_ url: URL) throws {
        switch kind(of: url) {
        case .regular: return
        case .missing: throw ArtifactBackupError.readFailed
        case .symlink, .directory, .other: throw ArtifactBackupError.unsafeContent
        }
    }

    /// `attributesOfItem` does not follow symbolic links, so a link is seen as
    /// a link instead of silently reading or writing its target.
    private static func kind(of url: URL) -> FileKind {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return .missing
        }
        switch attributes[.type] as? FileAttributeType {
        case .some(.typeSymbolicLink): return .symlink
        case .some(.typeRegular): return .regular
        case .some(.typeDirectory): return .directory
        default: return .other
        }
    }

    /// A new ciphertext output only: a real, private parent directory with no
    /// symlink anywhere above it, and nothing of anyone else's replaced.
    private static func prepareOutputLocation(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        guard kind(of: parent) == .directory else { throw ArtifactBackupError.unsafeContent }
        do { try ConfigBackupFiles.checkDirectory(parent) }
        catch { throw ArtifactBackupError.unsafeContent }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o022 == 0 else {
            throw ArtifactBackupError.unsafeContent
        }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw ArtifactBackupError.writeFailed
        }
        // Never replace an existing file — not a stale delta, not a dangling
        // symlink, not someone else's archive.
        guard kind(of: url) == .missing else { throw ArtifactBackupError.writeFailed }
    }

    private static func copyArchive(from source: URL, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ArtifactBackupError.writeFailed
        }
        do {
            guard let input = try? FileHandle(forReadingFrom: source) else {
                throw ArtifactBackupError.readFailed
            }
            defer { try? input.close() }
            let output: FileHandle
            do { output = try FileHandle(forWritingTo: destination) }
            catch { throw ArtifactBackupError.writeFailed }
            defer { try? output.close() }
            while true {
                try Task.checkCancellation()
                let block: Data?
                do { block = try input.read(upToCount: ArtifactBackupDigest.blockSize) }
                catch { throw ArtifactBackupError.readFailed }
                guard let block, !block.isEmpty else { break }
                do { try output.write(contentsOf: block) }
                catch { throw ArtifactBackupError.writeFailed }
            }
            do { try output.synchronize() } catch { throw ArtifactBackupError.writeFailed }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Header, one length-prefixed record per frame and a tag per frame.
    private static func estimatedSize(plaintext: Int64) -> Int64 {
        let chunk = Int64(ArtifactArchiveWriter.defaultChunkSize)
        let frames = plaintext / chunk + 1
        return Int64(ArtifactArchiveHeader.byteCount) + plaintext + frames * 20
    }

    private static func identity(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isSamePath(_ first: URL, _ second: URL) -> Bool {
        identity(of: first) == identity(of: second)
    }

    private static func summary(_ manifest: ArtifactBackupManifest, at url: URL) -> ArtifactBackupSummary {
        ArtifactBackupSummary(id: manifest.id, createdAt: manifest.createdAt,
                              totalBytes: fileSize(url), fileCount: manifest.entries.count,
                              sections: Set(manifest.sections))
    }
}
