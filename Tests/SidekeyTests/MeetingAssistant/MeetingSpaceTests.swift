import Foundation
import XCTest
@testable import Sidekey

final class MeetingSpaceTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-space-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func space(_ root: URL, scope: [String] = ["Sources"]) -> MeetingSpace {
        .init(version: 1, id: "project", name: "Project", purpose: "Context", instructions: "",
              sources: [.init(id: "repo", kind: "repository", name: "Repository", location: try! SpaceRepository.root(root.path).path, scope: scope, access: "read")])
    }
    func testCatalogIsolatesBadFilesAndRejectsTraversalAndUnknownFields() throws {
        let directory = try root()
        let good = space(directory)
        let data = try JSONEncoder().encode(good)
        try data.write(to: directory.appendingPathComponent("project.json"))
        try Data("{".utf8).write(to: directory.appendingPathComponent("bad.json"))
        let catalog = try MeetingSpace.load(directory: directory)
        XCTAssertEqual(catalog.spaces, [good]); XCTAssertEqual(catalog.invalidFiles, ["bad.json"])
        var bad = good; bad.sources[0].scope = ["../outside"]
        XCTAssertThrowsError(try MeetingSpace.decode(JSONEncoder().encode(bad), fileName: "project.json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var sources = try XCTUnwrap(object["sources"] as? [[String: Any]])
        sources[0]["write"] = true; object["sources"] = sources
        XCTAssertThrowsError(try MeetingSpace.decode(JSONSerialization.data(withJSONObject: object), fileName: "project.json"))
        XCTAssertThrowsError(try MeetingSpace.decode(data, fileName: "wrong.json"))
    }
    func testDescriptorReadsEnforceScopesAndRejectLinksAndSecrets() throws {
        let root = try root()
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("Allowed line\nsecond line".utf8).write(to: sources.appendingPathComponent("Good.swift"))
        try Data("outside".utf8).write(to: root.appendingPathComponent("Outside.txt"))
        try Data("private fixture".utf8).write(to: sources.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(at: sources.appendingPathComponent("Link.txt"), withDestinationURL: root.appendingPathComponent("Outside.txt"))
        try FileManager.default.createSymbolicLink(at: sources.appendingPathComponent("LinkedDir"), withDestinationURL: root)
        let repository = SpaceRepository(source: space(root).sources[0])
        XCTAssertEqual(try repository.read("Sources/Good.swift"), "1: Allowed line\n2: second line")
        for path in ["Outside.txt", "Sources/../Outside.txt", "Sources/.env", "Sources/Link.txt", "Sources/LinkedDir/Outside.txt", "/etc/passwd"] {
            XCTAssertThrowsError(try repository.read(path), path)
        }
        XCTAssertEqual(try repository.list(), ["Sources/"])
        XCTAssertEqual(try repository.list("Sources"), ["Sources/Good.swift"])
        XCTAssertTrue(try repository.search("Allowed").contains("Sources/Good.swift:1:"))
        XCTAssertFalse(try repository.search("outside").contains("Outside.txt"))
    }
    func testUnsafeRootsAndHiddenScopesAreRejected() throws {
        let root = try root()
        for path in ["/", FileManager.default.homeDirectoryForCurrentUser.path, "/System/Library", "/etc", "/Library/Keychains"] {
            var value = space(root); value.sources[0].location = path
            XCTAssertThrowsError(try MeetingSpace.decode(JSONEncoder().encode(value), fileName: "project.json"), path)
        }
        for scope in [".ssh", "Sources/.env", "Sources//file", "Sources/./file", "Sources/secrets.json"] {
            XCTAssertThrowsError(try MeetingSpace.decode(JSONEncoder().encode(space(root, scope: [scope])), fileName: "project.json"), scope)
        }
    }
    func testDatabaseDeclarationsDoNotOpenConnections() throws {
        let root = try root()
        var value = space(root)
        value.sources = [.init(id: "db", kind: "database", name: "Analytics", connection_ref: "case://project/analytics", scope: ["public.events"], access: "read")]
        XCTAssertEqual(try MeetingSpace.decode(JSONEncoder().encode(value), fileName: "project.json"), value)
        value.sources[0].connection_ref = "postgres://user:password@host/db"
        XCTAssertThrowsError(try MeetingSpace.decode(JSONEncoder().encode(value), fileName: "project.json"))
    }
    func testLargeMultibyteFilesKeepCompleteUTF8Prefix() throws {
        let root = try root()
        let repository = SpaceRepository(source: space(root, scope: ["."]).sources[0])
        for (index, character) in ["я", "語", "🎧"].enumerated() {
            let path = "large\(index).txt"
            let text = "a" + String(repeating: character, count: 20_000)
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
            let read = try repository.read(path)
            XCTAssertTrue(read.contains(character)); XCTAssertTrue(read.contains("сокращён"))
            XCTAssertFalse(read.contains("�"))
            XCTAssertTrue(try repository.search(character).contains(path))
        }
    }
    func testReplacedRootCannotAcquireAnotherDirectoryOnReload() throws {
        let parent = try root(), project = parent.appendingPathComponent("project"), other = parent.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let value = space(project, scope: ["."])
        let data = try JSONEncoder().encode(value)
        _ = try MeetingSpace.decode(data, fileName: "project.json")
        try FileManager.default.removeItem(at: project)
        try FileManager.default.createSymbolicLink(at: project, withDestinationURL: other)
        XCTAssertThrowsError(try MeetingSpace.decode(data, fileName: "project.json"))
        XCTAssertThrowsError(try SpaceRepository(source: value.sources[0]).list())
    }
}
