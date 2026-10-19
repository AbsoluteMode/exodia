import CryptoKit
import XCTest
@testable import Sidekey

/// The archive format carries everything private inside the encryption and
/// must detect a damaged, truncated or reordered file rather than decode a
/// shorter "valid" backup.
final class ArtifactBackupFormatTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-format-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func archiveURL() -> URL {
        directory.appendingPathComponent(UUID().uuidString + ".exodiabackup")
    }

    private func payload(_ size: Int) -> Data {
        var data = Data(count: size)
        for index in stride(from: 0, to: size, by: 97) { data[index] = UInt8(index % 251) }
        return data
    }

    func testStreamsManyFramesAndReadsEveryByteBack() throws {
        let url = archiveURL()
        let key = ArtifactBackupTestKeys.make()
        let body = payload(5 * 64 * 1024 + 77)
        let writer = try ArtifactArchiveWriter(url: url, archiveKey: key, chunkSize: 16 * 1024)
        try writer.append(body)
        try writer.finish()

        let reader = try ArtifactArchiveReader(url: url, archiveKey: key)
        var received = Data()
        try reader.forward(Int64(body.count)) { received.append($0) }
        try reader.verifyEnd()
        XCTAssertEqual(received, body)
        // More than one frame really was produced.
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(size, body.count)
        XCTAssertGreaterThan(size / (16 * 1024), 4)
    }

    func testSecretBytesAndFileNamesNeverAppearInTheArchive() throws {
        let url = archiveURL()
        let key = ArtifactBackupTestKeys.make()
        let writer = try ArtifactArchiveWriter(url: url, archiveKey: key, chunkSize: 16 * 1024)
        try writer.append(Data("synthetic-secret-value private-meeting-name.md".utf8))
        try writer.finish()
        let bytes = try Data(contentsOf: url)
        XCTAssertFalse(bytes.range(of: Data("synthetic-secret-value".utf8)) != nil)
        XCTAssertFalse(bytes.range(of: Data("private-meeting-name".utf8)) != nil)
    }

    func testWrongKeyCannotOpenAnyFrame() throws {
        let url = archiveURL()
        let writer = try ArtifactArchiveWriter(url: url, archiveKey: ArtifactBackupTestKeys.make(),
                                               chunkSize: 16 * 1024)
        try writer.append(payload(40_000))
        try writer.finish()
        let reader = try ArtifactArchiveReader(url: url, archiveKey: ArtifactBackupTestKeys.make())
        XCTAssertThrowsError(try reader.read(exactly: 16)) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .cannotUnlock)
        }
    }

    func testTruncatedArchiveIsRefusedInsteadOfDecodingShort() throws {
        let url = archiveURL()
        let key = ArtifactBackupTestKeys.make()
        let body = payload(50_000)
        let writer = try ArtifactArchiveWriter(url: url, archiveKey: key, chunkSize: 16 * 1024)
        try writer.append(body)
        try writer.finish()
        let full = try Data(contentsOf: url)
        try full.prefix(full.count - 4_000).write(to: url)

        let reader = try ArtifactArchiveReader(url: url, archiveKey: key)
        XCTAssertThrowsError(try reader.forward(Int64(body.count)) { _ in }) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .truncated)
        }
    }

    func testTamperedByteFailsAuthentication() throws {
        let url = archiveURL()
        let key = ArtifactBackupTestKeys.make()
        let writer = try ArtifactArchiveWriter(url: url, archiveKey: key, chunkSize: 16 * 1024)
        try writer.append(payload(30_000))
        try writer.finish()
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: url)
        let reader = try ArtifactArchiveReader(url: url, archiveKey: key)
        XCTAssertThrowsError(try reader.forward(30_000) { _ in })
    }

    func testReorderedFramesFailAuthentication() throws {
        let url = archiveURL()
        let key = ArtifactBackupTestKeys.make()
        let chunk = 16 * 1024
        let writer = try ArtifactArchiveWriter(url: url, archiveKey: key, chunkSize: chunk)
        try writer.append(payload(chunk * 3))
        try writer.finish()

        // Each non-final frame is 4 length bytes + chunk + 16 tag bytes, so
        // the first two can be swapped byte-exactly.
        let bytes = try Data(contentsOf: url)
        let head = ArtifactArchiveHeader.byteCount
        let frame = 4 + chunk + 16
        var reordered = bytes.prefix(head)
        reordered.append(bytes[(head + frame)..<(head + 2 * frame)])
        reordered.append(bytes[head..<(head + frame)])
        reordered.append(bytes[(head + 2 * frame)...])
        try reordered.write(to: url)

        let reader = try ArtifactArchiveReader(url: url, archiveKey: key)
        XCTAssertThrowsError(try reader.forward(Int64(chunk)) { _ in }) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .cannotUnlock)
        }
    }

    func testDroppedFinalFrameFlagIsDetected() throws {
        let url = archiveURL()
        let key = ArtifactBackupTestKeys.make()
        let writer = try ArtifactArchiveWriter(url: url, archiveKey: key, chunkSize: 16 * 1024)
        try writer.append(payload(1_000))
        try writer.finish()
        var bytes = try Data(contentsOf: url)
        // Clear the final-frame marker in the length field.
        bytes[ArtifactArchiveHeader.byteCount] &= 0x7F
        try bytes.write(to: url)
        let reader = try ArtifactArchiveReader(url: url, archiveKey: key)
        XCTAssertThrowsError(try reader.read(exactly: 1_000)) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .cannotUnlock)
        }
    }

    func testTrailingDataAfterTheFinalFrameIsRefused() throws {
        let url = archiveURL()
        let key = ArtifactBackupTestKeys.make()
        let writer = try ArtifactArchiveWriter(url: url, archiveKey: key, chunkSize: 16 * 1024)
        try writer.append(payload(1_000))
        try writer.finish()
        var bytes = try Data(contentsOf: url)
        bytes.append(contentsOf: [0, 0, 0, 32])
        bytes.append(Data(repeating: 7, count: 32))
        try bytes.write(to: url)
        let reader = try ArtifactArchiveReader(url: url, archiveKey: key)
        _ = try reader.read(exactly: 1_000)
        XCTAssertThrowsError(try reader.verifyEnd()) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .damaged)
        }
    }

    func testForeignAndFutureHeadersAreSeparateFailures() throws {
        let url = archiveURL()
        let key = ArtifactBackupTestKeys.make()
        try Data(repeating: 9, count: 64).write(to: url)
        XCTAssertThrowsError(try ArtifactArchiveReader(url: url, archiveKey: key)) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .notAnArchive)
        }
        let writer = try ArtifactArchiveWriter(url: url, archiveKey: key, chunkSize: 16 * 1024)
        try writer.append(Data("x".utf8))
        try writer.finish()
        var bytes = try Data(contentsOf: url)
        bytes[9] = 2
        try bytes.write(to: url)
        XCTAssertThrowsError(try ArtifactArchiveReader(url: url, archiveKey: key)) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .needsNewerApp)
        }
    }

    func testFutureManifestSchemaAsksForAnUpdate() throws {
        let manifest = ArtifactBackupManifest(
            schema: ArtifactBackupManifest.currentSchema + 1, id: UUID(), createdAt: Date(),
            flavor: "prod", appVersion: nil, appBuild: nil, sections: [.settings], entries: [],
            contentBytes: 0, warnings: [])
        let data = try JSONEncoder.artifactBackup.encode(manifest)
        XCTAssertThrowsError(try ArtifactBackupManifest.decode(data)) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .needsNewerApp)
        }
    }

    func testManifestRejectsMismatchedTotalsAndDuplicatePaths() throws {
        let entry = ArtifactBackupManifest.Entry(path: "settings/preferences.json", section: .settings,
                                                 bytes: 10, sha256: String(repeating: "a", count: 64))
        var manifest = ArtifactBackupManifest(id: UUID(), createdAt: Date(), flavor: "prod",
                                              appVersion: nil, appBuild: nil, sections: [.settings],
                                              entries: [entry], contentBytes: 11, warnings: [])
        XCTAssertThrowsError(try manifest.validate())
        manifest.contentBytes = 20
        manifest.entries = [entry, entry]
        XCTAssertThrowsError(try manifest.validate())
    }

    func testEntryPathsRejectTraversalAndUnknownRoots() {
        for path in ["../settings/preferences.json", "settings/../../etc/passwd", "/settings/x.json",
                     "secrets/key.json", "settings", "settings//x.json", "settings/.hidden",
                     "meetings/notes/a\u{0}b.md", "workspace/monitor/dash:board.json"] {
            XCTAssertThrowsError(try ArtifactBackupPath.validate(path), path) { error in
                XCTAssertEqual(error as? ArtifactBackupError, .unsafeContent, path)
            }
        }
        XCTAssertNoThrow(try ArtifactBackupPath.validate("meetings/staged/\(UUID().uuidString)/chunk-000.wav"))
    }
}
