import CryptoKit
import XCTest
@testable import Sidekey

/// Delta transport must never cost correctness: a reconstructed archive has to
/// be byte-for-byte the snapshot the user backed up, every dependency has to be
/// authenticated, and anything that does not add up — a wrong key, a tampered
/// or truncated link, a future format, a missing parent, a cycle, a chain that
/// disagrees about a file — must fail instead of producing a plausible archive.
///
/// Everything here is synthetic: temporary archives with made-up paths and
/// values, no Keychain, no stores, no network, no model calls.
final class BackupDeltaArchiveTests: XCTestCase {
    private struct Fixture {
        var path: String
        var section: ArtifactBackupSection
        var data: Data
    }

    /// Whole seconds: the manifest's own date encoding is ISO-8601, so this is
    /// what a round trip must reproduce exactly.
    private static let stamp = Date(timeIntervalSince1970: 1_780_000_000)

    private var directory = URL(fileURLWithPath: "/tmp")
    private var key = Data()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-delta-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        key = ArtifactBackupTestKeys.make()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    /// Deterministic filler built from one repeated block: large fixtures stay
    /// cheap to produce while every seed gives different bytes and digests.
    private func bytes(_ count: Int, seed: UInt8) -> Data {
        var block = Data(count: min(count, 64 * 1024))
        for index in 0..<block.count { block[index] = UInt8((index &* 31 &+ Int(seed)) % 251) }
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            data.append(block.prefix(min(block.count, count - data.count)))
        }
        return data
    }

    private func settings(_ marker: String) -> Fixture {
        Fixture(path: "settings/preferences.json", section: .settings,
                data: Data("{\"schema\":1,\"values\":{\"marker\":\"\(marker)\"}}".utf8))
    }

    private func manifest(_ fixtures: [Fixture], id: UUID = UUID(), createdAt: Date = stamp,
                          warnings: [String] = []) throws -> ArtifactBackupManifest {
        let sorted = fixtures.sorted { $0.path < $1.path }
        let entries = sorted.map {
            ArtifactBackupManifest.Entry(path: $0.path, section: $0.section,
                                         bytes: Int64($0.data.count),
                                         sha256: ArtifactBackupDigest.of($0.data))
        }
        let manifest = ArtifactBackupManifest(
            id: id, createdAt: createdAt, flavor: "prod", appVersion: "9.9.9", appBuild: "9999",
            sections: Set(entries.map(\.section)).sorted { $0.rawValue < $1.rawValue },
            entries: entries, contentBytes: entries.reduce(Int64(0)) { $0 + $1.bytes },
            warnings: warnings)
        try manifest.validate()
        return manifest
    }

    private func payloads(_ fixtures: [Fixture]) -> [String: Data] {
        Dictionary(fixtures.map { ($0.path, $0.data) }, uniquingKeysWith: { first, _ in first })
    }

    private func write(manifest: ArtifactBackupManifest, payloads: [String: Data], to url: URL,
                       chunkSize: Int = ArtifactArchiveWriter.defaultChunkSize) throws {
        let writer = try ArtifactArchiveWriter(url: url, archiveKey: key, chunkSize: chunkSize)
        let data = try manifest.encoded()
        try writer.append(Data(ArtifactArchiveHeader.bigEndian32(UInt32(data.count))))
        try writer.append(data)
        for entry in manifest.entries {
            try writer.append(try XCTUnwrap(payloads[entry.path]))
        }
        try writer.finish()
    }

    /// A synthetic standalone full archive, exactly as the engine lays one out.
    @discardableResult
    private func writeFull(_ fixtures: [Fixture], to url: URL, id: UUID = UUID(),
                           createdAt: Date = stamp, warnings: [String] = [],
                           chunkSize: Int = ArtifactArchiveWriter.defaultChunkSize) throws
        -> ArtifactBackupManifest {
        let manifest = try manifest(fixtures, id: id, createdAt: createdAt, warnings: warnings)
        try write(manifest: manifest, payloads: payloads(fixtures), to: url, chunkSize: chunkSize)
        return manifest
    }

    /// A hand-built delta, for the cases a correct `prepare` would never make.
    private func writeDelta(current: ArtifactBackupManifest, currentPayloads: [String: Data],
                            baseID: UUID, carried: [String], version: Int = 1,
                            overrideEntries: [ArtifactBackupManifest.Entry]? = nil,
                            to url: URL) throws {
        let metadata = BackupDeltaFormat.Metadata(version: version, baseID: baseID,
                                                  currentManifest: current)
        let metadataData = try JSONEncoder.artifactBackup.encode(metadata)
        let reserved = ArtifactBackupManifest.Entry(
            path: BackupDeltaFormat.metadataPath, section: BackupDeltaFormat.metadataSection,
            bytes: Int64(metadataData.count), sha256: ArtifactBackupDigest.of(metadataData))
        let entries = overrideEntries
            ?? current.entries.filter { carried.contains($0.path) }
        let all = [reserved] + entries
        var contents = currentPayloads
        contents[BackupDeltaFormat.metadataPath] = metadataData
        let manifest = ArtifactBackupManifest(
            id: current.id, createdAt: current.createdAt, flavor: current.flavor,
            appVersion: current.appVersion, appBuild: current.appBuild,
            sections: Set(all.map(\.section)).sorted { $0.rawValue < $1.rawValue },
            entries: all, contentBytes: all.reduce(Int64(0)) { $0 + $1.bytes }, warnings: [])
        try write(manifest: manifest, payloads: contents, to: url)
    }

    private func read(_ url: URL, key: Data? = nil)
        throws -> (manifest: ArtifactBackupManifest, payloads: [String: Data]) {
        let reader = try ArtifactArchiveReader(url: url, archiveKey: key ?? self.key)
        defer { reader.close() }
        let prefix = try reader.read(exactly: 4)
        let length = Int([UInt8](prefix).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        let manifest = try ArtifactBackupManifest.decode(try reader.read(exactly: length))
        var contents: [String: Data] = [:]
        for entry in manifest.entries {
            var data = Data()
            try reader.forward(entry.bytes) { data.append($0) }
            XCTAssertEqual(ArtifactBackupDigest.of(data), entry.sha256, entry.path)
            contents[entry.path] = data
        }
        try reader.verifyEnd()
        return (manifest, contents)
    }

    private func size(_ url: URL) throws -> Int64 {
        Int64(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    private func regularFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private func assertFails(_ expected: ArtifactBackupError, _ message: String = "",
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected) " + message)
        } catch let error as ArtifactBackupError {
            XCTAssertEqual(error, expected, message)
        } catch {
            XCTFail("expected \(expected), got \(error) " + message)
        }
    }

    private func assertThrows(_ message: String = "", _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected a failure " + message)
        } catch {}
    }

    // MARK: - Delta size

    func testSmallSettingsChangeShipsFractionOfAFullArchiveWithALargeImage() async throws {
        let image = Fixture(path: "history/assets/shot.png", section: .history,
                            data: bytes(6 * 1024 * 1024, seed: 7))
        let first = url("first.exodiabackup")
        let second = url("second.exodiabackup")
        let base = try writeFull([settings("one"), image], to: first)
        let current = try writeFull([settings("two"), image], to: second)

        let delta = url("delta.exodiabackup")
        let prepared = try await BackupDeltaArchive().prepare(full: second, base: first,
                                                              output: delta, key: key)
        XCTAssertEqual(prepared.file, delta)
        XCTAssertEqual(prepared.baseID, base.id)
        XCTAssertEqual(try permissions(delta), 0o600)

        let fullSize = try size(second)
        let deltaSize = try size(delta)
        XCTAssertLessThan(Double(deltaSize), Double(fullSize) * 0.1,
                          "delta \(deltaSize) vs full \(fullSize)")

        // The delta carries only the reserved metadata and the changed file.
        let written = try read(delta)
        XCTAssertEqual(written.manifest.entries.map(\.path),
                       [BackupDeltaFormat.metadataPath, "settings/preferences.json"])

        let output = url("rebuilt.exodiabackup")
        let summary = try await BackupDeltaArchive().reconstruct(chain: [delta, first],
                                                                 output: output, key: key)
        let rebuilt = try read(output)
        XCTAssertEqual(rebuilt.manifest, current)
        XCTAssertEqual(rebuilt.payloads, payloads([settings("two"), image]))
        XCTAssertEqual(summary.id, current.id)
        XCTAssertEqual(summary.fileCount, current.entries.count)
        XCTAssertEqual(summary.sections, Set(current.sections))
        XCTAssertEqual(try permissions(output), 0o600)
        // The reconstructed archive is an ordinary full archive.
        let rebuiltBase = try await BackupDeltaArchive().baseID(in: output, key: key)
        XCTAssertNil(rebuiltBase)
        XCTAssertEqual(try ArtifactRestoreTransaction.validateArchive(at: output, key: key), current)
    }

    func testTooSmallASavingSendsTheFullArchiveInstead() async throws {
        let first = url("first.exodiabackup")
        let second = url("second.exodiabackup")
        try writeFull([settings("one"), Fixture(path: "history/assets/a.png", section: .history,
                                                data: bytes(400_000, seed: 1))], to: first)
        try writeFull([settings("two"), Fixture(path: "history/assets/a.png", section: .history,
                                                data: bytes(400_000, seed: 2))], to: second)
        let delta = url("delta.exodiabackup")
        let prepared = try await BackupDeltaArchive().prepare(full: second, base: first,
                                                              output: delta, key: key)
        XCTAssertEqual(prepared.file, second)
        XCTAssertNil(prepared.baseID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: delta.path))
    }

    func testNoBaseReturnsTheFullArchiveUnchanged() async throws {
        let full = url("full.exodiabackup")
        let manifest = try writeFull([settings("one")], to: full)
        let before = try Data(contentsOf: full)
        let prepared = try await BackupDeltaArchive().prepare(full: full, base: nil,
                                                              output: url("unused"), key: key)
        XCTAssertEqual(prepared.file, full)
        XCTAssertNil(prepared.baseID)
        XCTAssertEqual(try Data(contentsOf: full), before)
        let fullBase = try await BackupDeltaArchive().baseID(in: full, key: key)
        XCTAssertNil(fullBase)
        XCTAssertEqual(try read(full).manifest, manifest)
    }

    func testSingleFullChainIsValidatedAndCopiedUnchanged() async throws {
        let full = url("full.exodiabackup")
        let manifest = try writeFull([settings("one"), Fixture(path: "meetings/notes/\(UUID().uuidString).md",
                                                               section: .meetings,
                                                               data: Data("# synthetic".utf8))], to: full)
        let output = url("copy.exodiabackup")
        let summary = try await BackupDeltaArchive().reconstruct(chain: [full], output: output, key: key)
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: full))
        XCTAssertEqual(summary.id, manifest.id)
        XCTAssertEqual(summary.createdAt, manifest.createdAt)
        XCTAssertEqual(try permissions(output), 0o600)
    }

    func testAnUnchangedSnapshotShipsOnlyItsMetadata() async throws {
        let image = Fixture(path: "history/assets/a.png", section: .history,
                            data: bytes(1024 * 1024, seed: 25))
        let same = settings("same")
        let first = url("first.exodiabackup")
        let base = try writeFull([same, image], to: first)
        // Same content, new snapshot: only the metadata entry has to travel.
        let second = url("second.exodiabackup")
        let current = try writeFull([same, image], to: second)
        let delta = url("delta.exodiabackup")
        let prepared = try await BackupDeltaArchive().prepare(full: second, base: first,
                                                              output: delta, key: key)
        XCTAssertEqual(prepared.file, delta)
        XCTAssertEqual(prepared.baseID, base.id)
        XCTAssertEqual(try read(delta).manifest.entries.map(\.path), [BackupDeltaFormat.metadataPath])

        let output = url("rebuilt.exodiabackup")
        try await BackupDeltaArchive().reconstruct(chain: [delta, first], output: output, key: key)
        let rebuilt = try read(output)
        XCTAssertEqual(rebuilt.manifest, current)
        XCTAssertNotEqual(current.id, base.id)
        XCTAssertEqual(rebuilt.payloads, payloads([same, image]))
    }

    // MARK: - Multi-generation reconstruction

    func testMultipleGenerationsRecoverTheLatestSnapshotExactly() async throws {
        let archive = BackupDeltaArchive()
        let keep = Fixture(path: "meetings/notes/\(UUID().uuidString).md", section: .meetings,
                           data: bytes(300_000, seed: 3))
        let removed = Fixture(path: "history/assets/removed.png", section: .history,
                              data: bytes(900_000, seed: 4))
        let firstSettings = settings("gen-one")

        let first = url("gen1.exodiabackup")
        let generation1 = try writeFull([firstSettings, keep, removed], to: first,
                                        warnings: ["synthetic warning one"])

        // Generation 2: settings modified, one file deleted, one added.
        let added = Fixture(path: "workspace/monitor/dashboards/board.json", section: .workspace,
                            data: bytes(50_000, seed: 5))
        let secondSettings = settings("gen-two")
        let second = url("gen2.exodiabackup")
        let generation2 = try writeFull([secondSettings, keep, added], to: second,
                                        warnings: ["synthetic warning two"])
        let delta2 = url("delta2.exodiabackup")
        let prepared2 = try await archive.prepare(full: second, base: first, output: delta2, key: key)
        XCTAssertEqual(prepared2.file, delta2)
        XCTAssertEqual(prepared2.baseID, generation1.id)

        // Generation 3: the added file is modified, another is added, `keep`
        // still comes from generation 1.
        let changedAdded = Fixture(path: added.path, section: .workspace, data: bytes(70_000, seed: 6))
        let extra = Fixture(path: "credentials/providers.json", section: .credentials,
                            data: Data("{\"schema\":1,\"accounts\":{}}".utf8))
        let third = url("gen3.exodiabackup")
        let generation3 = try writeFull([secondSettings, keep, changedAdded, extra], to: third,
                                        warnings: ["synthetic warning three", "another"])
        let delta3 = url("delta3.exodiabackup")
        let prepared3 = try await archive.prepare(full: third, base: delta2, output: delta3, key: key)
        XCTAssertEqual(prepared3.file, delta3)
        XCTAssertEqual(prepared3.baseID, generation2.id)
        let third3Base = try await archive.baseID(in: delta3, key: key)
        let second2Base = try await archive.baseID(in: delta2, key: key)
        XCTAssertEqual(third3Base, generation2.id)
        XCTAssertEqual(second2Base, generation1.id)

        let output = url("rebuilt.exodiabackup")
        let summary = try await archive.reconstruct(chain: [delta3, delta2, first],
                                                    output: output, key: key)
        let rebuilt = try read(output)
        XCTAssertEqual(rebuilt.manifest, generation3)
        XCTAssertEqual(rebuilt.manifest.warnings, ["synthetic warning three", "another"])
        XCTAssertEqual(rebuilt.payloads,
                       payloads([secondSettings, keep, changedAdded, extra]))
        XCTAssertNil(rebuilt.payloads[removed.path], "a deleted file must not come back")
        XCTAssertNil(rebuilt.payloads[BackupDeltaFormat.metadataPath],
                     "the reserved entry is not user content")
        XCTAssertEqual(summary.fileCount, 4)
        XCTAssertEqual(try ArtifactRestoreTransaction.validateArchive(at: output, key: key),
                       generation3)
        let outputBase = try await archive.baseID(in: output, key: key)
        XCTAssertNil(outputBase)
    }

    func testUnchangedBytesComeFromTheOldestAncestorThroughManyFrames() async throws {
        // 12 MiB behind 64 KiB frames: the indexed reader has to seek through
        // nearly two hundred authenticated frames of the oldest archive.
        let large = Fixture(path: "meetings/staged/\(UUID().uuidString)/chunk-0001.wav",
                            section: .meetings, data: bytes(12 * 1024 * 1024, seed: 9))
        let first = url("gen1.exodiabackup")
        try writeFull([settings("one"), large], to: first, chunkSize: 64 * 1024)
        let second = url("gen2.exodiabackup")
        let current = try writeFull([settings("two"), large], to: second, chunkSize: 64 * 1024)
        let delta = url("delta.exodiabackup")
        let prepared = try await BackupDeltaArchive().prepare(full: second, base: first,
                                                              output: delta, key: key)
        XCTAssertEqual(prepared.file, delta)

        let output = url("rebuilt.exodiabackup")
        try await BackupDeltaArchive().reconstruct(chain: [delta, first], output: output, key: key)
        let rebuilt = try read(output)
        XCTAssertEqual(rebuilt.manifest, current)
        XCTAssertEqual(rebuilt.payloads[large.path], large.data)
    }

    // MARK: - Secrets

    func testProviderKeysAndCaseKeyBytesNeverLeaveEncryptionOrLandOnDisk() async throws {
        let keyMarker = "synthetic-case-key-marker"
        var caseKey = Data(keyMarker.utf8)
        caseKey.append(bytes(32 - caseKey.count, seed: 11))
        let credentials = Fixture(path: "credentials/providers.json", section: .credentials,
                                  data: Data("{\"schema\":1,\"accounts\":{\"openrouter\":\"synthetic-provider-secret\"}}".utf8))
        let vault = Fixture(path: "case/vault.key", section: .caseVault, data: caseKey)
        let secret = Fixture(path: "case/vault.enc", section: .caseVault, data: bytes(4096, seed: 12))

        let first = url("first.exodiabackup")
        try writeFull([settings("one"), credentials, vault, secret], to: first)
        let second = url("second.exodiabackup")
        try writeFull([settings("two"), credentials, vault, secret], to: second)
        let delta = url("delta.exodiabackup")
        let prepared = try await BackupDeltaArchive().prepare(full: second, base: first,
                                                              output: delta, key: key)
        XCTAssertEqual(prepared.file, delta)
        let output = url("rebuilt.exodiabackup")
        try await BackupDeltaArchive().reconstruct(chain: [delta, first], output: output, key: key)

        let markers = ["synthetic-provider-secret", keyMarker, "vault.key", "preferences.json"]
        let files = try regularFiles()
        XCTAssertEqual(Set(files.map(\.lastPathComponent)),
                       ["first.exodiabackup", "second.exodiabackup", "delta.exodiabackup",
                        "rebuilt.exodiabackup"],
                       "no plaintext temporary file may be left behind")
        for file in files {
            let data = try Data(contentsOf: file)
            for marker in markers {
                XCTAssertNil(data.range(of: Data(marker.utf8)),
                             "\(marker) appeared in \(file.lastPathComponent)")
            }
        }
        // The secrets still survive the round trip, inside the encryption.
        let rebuilt = try read(output)
        XCTAssertEqual(rebuilt.payloads[vault.path], caseKey)
        XCTAssertEqual(rebuilt.payloads[credentials.path], credentials.data)
    }

    // MARK: - Refusals

    func testWrongKeyCannotPrepareInspectOrReconstruct() async throws {
        let shared = Fixture(path: "history/assets/a.png", section: .history,
                             data: bytes(1024 * 1024, seed: 23))
        let first = url("first.exodiabackup")
        try writeFull([settings("one"), shared], to: first)
        let second = url("second.exodiabackup")
        try writeFull([settings("two"), shared], to: second)
        let delta = url("delta.exodiabackup")
        let prepared = try await BackupDeltaArchive().prepare(full: second, base: first,
                                                              output: delta, key: key)
        XCTAssertEqual(prepared.file, delta)

        let other = ArtifactBackupTestKeys.make()
        await assertFails(.cannotUnlock, "prepare") {
            _ = try await BackupDeltaArchive().prepare(full: second, base: first,
                                                       output: self.url("x1"), key: other)
        }
        await assertFails(.cannotUnlock, "baseID") {
            _ = try await BackupDeltaArchive().baseID(in: delta, key: other)
        }
        await assertFails(.cannotUnlock, "reconstruct") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [delta, first],
                                                           output: self.url("x2"), key: other)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("x2").path))
    }

    func testTamperedAndTruncatedLinksAreRefused() async throws {
        let first = url("first.exodiabackup")
        try writeFull([settings("one"), Fixture(path: "history/assets/a.png", section: .history,
                                                data: bytes(300_000, seed: 13))], to: first)
        let second = url("second.exodiabackup")
        try writeFull([settings("two"), Fixture(path: "history/assets/a.png", section: .history,
                                                data: bytes(300_000, seed: 13))], to: second)
        let delta = url("delta.exodiabackup")
        _ = try await BackupDeltaArchive().prepare(full: second, base: first, output: delta, key: key)

        // A flipped byte inside the newest link.
        let tampered = url("tampered.exodiabackup")
        var deltaBytes = try Data(contentsOf: delta)
        deltaBytes[deltaBytes.count - 20] ^= 0x40
        try deltaBytes.write(to: tampered)
        await assertThrows("tampered delta, baseID") {
            _ = try await BackupDeltaArchive().baseID(in: tampered, key: self.key)
        }
        await assertThrows("tampered delta, reconstruct") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [tampered, first],
                                                           output: self.url("t1"), key: self.key)
        }

        // A flipped byte deep inside the ancestor that owns the image.
        let tamperedBase = url("tampered-base.exodiabackup")
        var baseBytes = try Data(contentsOf: first)
        baseBytes[baseBytes.count / 2] ^= 0x01
        try baseBytes.write(to: tamperedBase)
        await assertFails(.cannotUnlock, "tampered ancestor") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [delta, tamperedBase],
                                                           output: self.url("t2"), key: self.key)
        }

        // A link whose end never arrived.
        let cut = url("cut.exodiabackup")
        try deltaBytes.prefix(deltaBytes.count - 64).write(to: cut)
        await assertFails(.truncated, "truncated delta") {
            _ = try await BackupDeltaArchive().baseID(in: cut, key: self.key)
        }
        let cutBase = url("cut-base.exodiabackup")
        try baseBytes.prefix(baseBytes.count - 64).write(to: cutBase)
        await assertFails(.truncated, "truncated ancestor") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [delta, cutBase],
                                                           output: self.url("t3"), key: self.key)
        }
        // Trailing bytes are damage, not a longer archive.
        let padded = url("padded.exodiabackup")
        try (deltaBytes + Data([0x00, 0x01])).write(to: padded)
        await assertFails(.damaged, "trailing data") {
            _ = try await BackupDeltaArchive().baseID(in: padded, key: self.key)
        }
        for name in ["t1", "t2", "t3"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url(name).path), name)
        }
    }

    func testFutureMetadataAsksForANewerApp() async throws {
        let first = url("first.exodiabackup")
        let base = try writeFull([settings("one")], to: first)
        let changed = settings("two")
        let current = try manifest([changed])
        let delta = url("future.exodiabackup")
        try writeDelta(current: current, currentPayloads: payloads([changed]), baseID: base.id,
                       carried: [changed.path], version: BackupDeltaFormat.currentVersion + 1,
                       to: delta)
        await assertFails(.needsNewerApp, "baseID") {
            _ = try await BackupDeltaArchive().baseID(in: delta, key: self.key)
        }
        await assertFails(.needsNewerApp, "reconstruct") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [delta, first],
                                                           output: self.url("out"), key: self.key)
        }
        // A newer base is not a failure: the validated full archive still goes.
        let second = url("second.exodiabackup")
        try writeFull([changed], to: second)
        let prepared = try await BackupDeltaArchive().prepare(full: second, base: delta,
                                                              output: url("d"), key: key)
        XCTAssertEqual(prepared.file, second)
        XCTAssertNil(prepared.baseID)
    }

    func testMissingParentSelfReferenceAndCyclesAreRefused() async throws {
        let first = url("first.exodiabackup")
        let base = try writeFull([settings("one")], to: first)
        let changed = settings("two")
        let current = try manifest([changed])
        let delta = url("delta.exodiabackup")
        try writeDelta(current: current, currentPayloads: payloads([changed]), baseID: base.id,
                       carried: [changed.path], to: delta)

        // A delta can never be the whole chain.
        await assertFails(.incompleteArchive(BackupDeltaFormat.metadataPath), "lone delta") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [delta], output: self.url("o1"),
                                                           key: self.key)
        }
        // A chain that ends in the wrong snapshot.
        let unrelated = url("unrelated.exodiabackup")
        try writeFull([settings("other")], to: unrelated)
        await assertFails(.incompleteArchive("backup base"), "wrong parent") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [delta, unrelated],
                                                           output: self.url("o2"), key: self.key)
        }
        // A chain that never reaches a standalone full archive.
        let other = try manifest([settings("three")])
        let second = url("second-delta.exodiabackup")
        try writeDelta(current: other, currentPayloads: payloads([settings("three")]),
                       baseID: current.id, carried: [], to: second)
        await assertFails(.incompleteArchive("backup base"), "no full at the end") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [second, delta],
                                                           output: self.url("o3"), key: self.key)
        }
        // A delta that claims itself as its own parent.
        let loop = url("loop.exodiabackup")
        try writeDelta(current: current, currentPayloads: payloads([changed]), baseID: current.id,
                       carried: [changed.path], to: loop)
        await assertFails(.damaged, "self reference") {
            _ = try await BackupDeltaArchive().baseID(in: loop, key: self.key)
        }
        // A repeated archive cannot pad a chain.
        await assertFails(.damaged, "duplicate link") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [delta, delta, first],
                                                           output: self.url("o4"), key: self.key)
        }
        // Longer than the bounded chain.
        await assertFails(.tooLarge, "chain length") {
            _ = try await BackupDeltaArchive().reconstruct(
                chain: Array(repeating: first, count: BackupDeltaFormat.maxChainLength + 1),
                output: self.url("o5"), key: self.key)
        }
        for name in ["o1", "o2", "o3", "o4", "o5"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url(name).path), name)
        }
    }

    func testAChainThatDisagreesAboutAFileIsRefused() async throws {
        let image = Fixture(path: "history/assets/a.png", section: .history, data: bytes(40_000, seed: 15))
        let first = url("first.exodiabackup")
        let base = try writeFull([settings("one"), image], to: first)
        let current = try manifest([settings("two"), image])

        // A carried entry whose digest does not match the snapshot manifest.
        let mismatched = url("mismatched.exodiabackup")
        var entries = current.entries.filter { $0.path == "settings/preferences.json" }
        entries[0].sha256 = String(repeating: "a", count: 64)
        try writeDelta(current: current, currentPayloads: payloads([settings("two"), image]),
                       baseID: base.id, carried: [], overrideEntries: entries, to: mismatched)
        await assertFails(.damaged, "digest mismatch") {
            _ = try await BackupDeltaArchive().baseID(in: mismatched, key: self.key)
        }

        // A carried entry the snapshot manifest does not mention at all.
        let stranger = url("stranger.exodiabackup")
        let orphan = Fixture(path: "history/assets/orphan.png", section: .history,
                             data: bytes(1_000, seed: 16))
        let orphanEntry = ArtifactBackupManifest.Entry(path: orphan.path, section: orphan.section,
                                                       bytes: Int64(orphan.data.count),
                                                       sha256: ArtifactBackupDigest.of(orphan.data))
        try writeDelta(current: current,
                       currentPayloads: payloads([settings("two"), image, orphan]),
                       baseID: base.id, carried: [], overrideEntries: [orphanEntry], to: stranger)
        await assertFails(.damaged, "unknown carried path") {
            _ = try await BackupDeltaArchive().baseID(in: stranger, key: self.key)
        }

        // An ancestor that no longer holds the bytes the snapshot describes.
        let drifted = url("drifted.exodiabackup")
        try writeFull([settings("one"), Fixture(path: image.path, section: .history,
                                                data: bytes(40_000, seed: 17))],
                      to: drifted, id: base.id)
        let honest = url("honest-delta.exodiabackup")
        try writeDelta(current: current, currentPayloads: payloads([settings("two")]),
                       baseID: base.id, carried: ["settings/preferences.json"], to: honest)
        await assertFails(.damaged, "ancestor disagrees") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [honest, drifted],
                                                           output: self.url("o"), key: self.key)
        }
    }

    func testReservedMetadataPathIsNeverTreatedAsUserContent() async throws {
        // An archive that claims the reserved path as one of the user's files.
        let impostor = Fixture(path: BackupDeltaFormat.metadataPath, section: .settings,
                               data: Data("{\"version\":1}".utf8))
        let full = url("impostor.exodiabackup")
        try writeFull([settings("one"), impostor], to: full)
        await assertFails(.invalidContent("backup delta"), "prepare") {
            _ = try await BackupDeltaArchive().prepare(full: full, base: nil,
                                                       output: self.url("o1"), key: self.key)
        }
        await assertFails(.incompleteArchive(BackupDeltaFormat.metadataPath), "reconstruct") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [full], output: self.url("o2"),
                                                           key: self.key)
        }
        // And one whose snapshot manifest smuggles it in.
        let smuggled = try manifest([settings("two"), impostor])
        let delta = url("smuggled.exodiabackup")
        try writeDelta(current: smuggled, currentPayloads: payloads([settings("two"), impostor]),
                       baseID: UUID(), carried: [], to: delta)
        await assertThrows("smuggled snapshot") {
            _ = try await BackupDeltaArchive().baseID(in: delta, key: self.key)
        }
    }

    func testInputSymlinksAreRejected() async throws {
        let full = url("full.exodiabackup")
        try writeFull([settings("one")], to: full)
        let link = url("link.exodiabackup")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: full)

        await assertFails(.unsafeContent, "full input") {
            _ = try await BackupDeltaArchive().prepare(full: link, base: nil,
                                                       output: self.url("o1"), key: self.key)
        }
        await assertFails(.unsafeContent, "base input") {
            _ = try await BackupDeltaArchive().prepare(full: full, base: link,
                                                       output: self.url("o2"), key: self.key)
        }
        await assertFails(.unsafeContent, "chain input") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [link], output: self.url("o3"),
                                                           key: self.key)
        }
        // A symlink in the output position is not followed either.
        let outputLink = url("out-link.exodiabackup")
        try FileManager.default.createSymbolicLink(at: outputLink,
                                                   withDestinationURL: url("elsewhere"))
        await assertFails(.writeFailed, "output symlink") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [full], output: outputLink,
                                                           key: self.key)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("elsewhere").path))
    }

    func testAnUnusableBaseFallsBackToTheFullArchiveButABadCurrentFails() async throws {
        let full = url("full.exodiabackup")
        try writeFull([settings("one")], to: full)

        // Not an archive at all.
        let garbage = url("garbage.bin")
        try Data(repeating: 0x5A, count: 4096).write(to: garbage)
        var prepared = try await BackupDeltaArchive().prepare(full: full, base: garbage,
                                                              output: url("d1"), key: key)
        XCTAssertEqual(prepared.file, full)
        XCTAssertNil(prepared.baseID)

        // A real archive sealed under a different key.
        let foreign = url("foreign.exodiabackup")
        let foreignKey = ArtifactBackupTestKeys.make()
        let writer = try ArtifactArchiveWriter(url: foreign, archiveKey: foreignKey)
        try writer.append(Data("not yours".utf8))
        try writer.finish()
        prepared = try await BackupDeltaArchive().prepare(full: full, base: foreign,
                                                          output: url("d2"), key: key)
        XCTAssertEqual(prepared.file, full)
        XCTAssertNil(prepared.baseID)

        // A base that is simply not there.
        prepared = try await BackupDeltaArchive().prepare(full: full, base: url("absent"),
                                                          output: url("d3"), key: key)
        XCTAssertEqual(prepared.file, full)
        XCTAssertNil(prepared.baseID)
        for name in ["d1", "d2", "d3"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url(name).path), name)
        }

        // A damaged current archive is never hidden by that fallback.
        let broken = url("broken.exodiabackup")
        var bytes = try Data(contentsOf: full)
        bytes[bytes.count - 10] ^= 0x7F
        try bytes.write(to: broken)
        await assertFails(.cannotUnlock, "damaged current") {
            _ = try await BackupDeltaArchive().prepare(full: broken, base: nil,
                                                       output: self.url("d4"), key: self.key)
        }
        await assertFails(.readFailed, "missing current") {
            _ = try await BackupDeltaArchive().prepare(full: self.url("absent"), base: nil,
                                                       output: self.url("d5"), key: self.key)
        }
    }

    func testExistingOutputIsNeverReplaced() async throws {
        let shared = Fixture(path: "history/assets/a.png", section: .history,
                             data: bytes(2 * 1024 * 1024, seed: 19))
        let first = url("first.exodiabackup")
        try writeFull([settings("one"), shared], to: first)
        let second = url("second.exodiabackup")
        try writeFull([settings("two"), shared], to: second)
        let occupied = url("occupied.exodiabackup")
        try Data("someone else's file".utf8).write(to: occupied)
        await assertFails(.writeFailed, "prepare") {
            _ = try await BackupDeltaArchive().prepare(full: second, base: first,
                                                       output: occupied, key: self.key)
        }
        await assertFails(.writeFailed, "reconstruct") {
            _ = try await BackupDeltaArchive().reconstruct(chain: [second], output: occupied,
                                                           key: self.key)
        }
        XCTAssertEqual(try Data(contentsOf: occupied), Data("someone else's file".utf8))
    }

    func testCancellationRemovesThePartialOutput() async throws {
        let large = Fixture(path: "meetings/staged/\(UUID().uuidString)/chunk-0001.wav",
                            section: .meetings, data: bytes(24 * 1024 * 1024, seed: 21))
        let first = url("first.exodiabackup")
        try writeFull([settings("one"), large], to: first)
        let second = url("second.exodiabackup")
        try writeFull([settings("two"), large], to: second)
        let delta = url("delta.exodiabackup")
        _ = try await BackupDeltaArchive().prepare(full: second, base: first, output: delta, key: key)

        let archive = BackupDeltaArchive()
        let output = url("cancelled.exodiabackup")
        let chain = [delta, first]
        let archiveKey = key
        let task = Task.detached {
            try await archive.reconstruct(chain: chain, output: output, key: archiveKey)
        }
        task.cancel()
        do {
            _ = try await task.value
            throw XCTSkip("reconstruction finished before the cancellation landed")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }
}
