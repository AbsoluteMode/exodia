import XCTest
@testable import Sidekey

final class ConfigBackupFilesTests: XCTestCase {
    func testPrivateAtomicVersionsSurviveAnUnreadableSibling() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ConfigBackupFiles.ensurePrivateDirectory(root)
        let store = ConfigBackupFiles(root: root)
        let key = ConfigBackupArchive.makeKey()
        let snapshot = ConfigBackupSnapshot(reason: "Saved version", preferences: [:])
        let url = try await store.save(ConfigBackupArchive.seal(snapshot, key: key), id: snapshot.id)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let invalid = root.appendingPathComponent(UUID().uuidString + ".exodiabackup")
        try Data("damaged".utf8).write(to: invalid)
        let loaded = try await store.load(key: key)
        XCTAssertEqual(loaded, [snapshot])
        try await store.prune(removing: [snapshot.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
    }

    func testRejectsSymlinkForReadingAndWriting() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("unchanged.txt")
        try Data("unchanged".utf8).write(to: victim)
        let id = UUID()
        let link = root.appendingPathComponent(id.uuidString.lowercased() + ".exodiabackup")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        let store = ConfigBackupFiles(root: root)
        do { _ = try await store.save(Data("replace".utf8), id: id); XCTFail("Must reject symbolic links") }
        catch {}
        do { _ = try await store.read(link); XCTFail("Must reject symbolic links") }
        catch {}
        XCTAssertEqual(try String(contentsOf: victim), "unchanged")
    }

    func testTwoDevicesKeepIndependentVersionFiles() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ConfigBackupFiles.ensurePrivateDirectory(root)
        let store = ConfigBackupFiles(root: root)
        let first = try await store.save(Data([1]), id: UUID())
        let second = try await store.save(Data([2]), id: UUID())
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
    }
    func testRecoveryRetainsHistoryWrittenWithThePreviousLocalKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ConfigBackupFiles(root: root)
        let firstKey = ConfigBackupArchive.makeKey(), secondKey = ConfigBackupArchive.makeKey()
        let first = ConfigBackupSnapshot(reason: "Before recovery", preferences: [:])
        let second = ConfigBackupSnapshot(reason: "After recovery", preferences: ["sidekey.models.byokProvider": .string("soniox")])
        _ = try await files.save(ConfigBackupArchive.seal(first, key: firstKey), id: first.id)
        _ = try await files.save(ConfigBackupArchive.seal(second, key: secondKey), id: second.id)
        let versions = try await files.load(keys: [firstKey, secondKey])
        XCTAssertEqual(Set(versions.map(\.id)), [first.id, second.id])
    }

}
