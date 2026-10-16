import XCTest
@testable import Sidekey

@MainActor
final class ProjectKnowledgeStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func folder(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRetrievalIsScopedAndCarriesSchemaSourceLines() async throws {
        let first = try folder("first"), second = try folder("second")
        try "CREATE TYPE status AS ENUM ('draft', 'active');".write(to: first.appendingPathComponent("schema.sql"), atomically: true, encoding: .utf8)
        try "status: other-client-only".write(to: second.appendingPathComponent("schema.yaml"), atomically: true, encoding: .utf8)
        let store = ProjectKnowledgeStore(directory: directory.appendingPathComponent("library"))
        let firstID = try XCTUnwrap(store.addProject(name: "First", folder: first))
        let secondID = try XCTUnwrap(store.addProject(name: "Second", folder: second))
        await store.reindex(firstID); await store.reindex(secondID)
        store.selectProject(firstID)
        let context = try XCTUnwrap(store.activeProjectContext(query: "status"))
        XCTAssertEqual(context.projectID, firstID)
        XCTAssertTrue(context.sourceExcerpts.contains("schema.sql:1-1"))
        XCTAssertTrue(context.sourceExcerpts.contains("'draft', 'active'"))
        XCTAssertFalse(context.sourceExcerpts.contains("other-client-only"))
        store.selectProject(nil)
        XCTAssertNil(store.activeProjectContext(query: "status"))
    }

    func testScannerExcludesSecretsBuildAndSymlinkTargets() throws {
        let project = try folder("project"), outside = try folder("outside")
        let excluded = project.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        for name in [".env", "credentials.json", "secrets.yaml"] {
            try "private-fixture".write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "dependency-fixture".write(to: excluded.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try "outside-fixture".write(to: outside.appendingPathComponent("schema.sql"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("linked"), withDestinationURL: outside)
        try "allowed schema".write(to: project.appendingPathComponent("schema.sql"), atomically: true, encoding: .utf8)
        let scan = try ProjectKnowledgeScanner.scan(folder: project)
        XCTAssertEqual(scan.files, 1)
        XCTAssertEqual(scan.chunks.map(\.text), ["allowed schema"])
    }

    func testFailedReindexPreservesPreviousEvidence() async throws {
        let project = try folder("project")
        try "status allowed draft".write(to: project.appendingPathComponent("schema.sql"), atomically: true, encoding: .utf8)
        let store = ProjectKnowledgeStore(directory: directory.appendingPathComponent("library"))
        let id = try XCTUnwrap(store.addProject(name: "Project", folder: project))
        await store.reindex(id)
        try FileManager.default.removeItem(at: project)
        await store.reindex(id)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.search(projectID: id, query: "status").first?.text, "status allowed draft")
    }

    func testReindexRemovesDeletedSourceChunks() async throws {
        let project = try folder("project"), source = project.appendingPathComponent("schema.sql")
        try "status allowed draft".write(to: source, atomically: true, encoding: .utf8)
        let store = ProjectKnowledgeStore(directory: directory.appendingPathComponent("library"))
        let id = try XCTUnwrap(store.addProject(name: "Project", folder: project))
        await store.reindex(id)
        try FileManager.default.removeItem(at: source)
        await store.reindex(id)
        XCTAssertTrue(store.search(projectID: id, query: "status").isEmpty)
    }

    func testProjectNotesAndActiveSelectionSurviveRelaunch() throws {
        let project = try folder("project"), library = directory.appendingPathComponent("library")
        let store = ProjectKnowledgeStore(directory: library)
        let id = try XCTUnwrap(store.addProject(name: "Project", folder: project))
        store.saveNotes("Status is defined in schema.sql", projectID: id)
        let restored = ProjectKnowledgeStore(directory: library)
        XCTAssertEqual(restored.activeProjectID, id)
        XCTAssertTrue(try XCTUnwrap(restored.activeProjectContext(query: "status")).sourceExcerpts.contains("Status is defined in schema.sql"))
        restored.removeProject(id)
        XCTAssertNil(restored.activeProjectContext(query: "status"))
        XCTAssertTrue(ProjectKnowledgeStore(directory: library).projects.isEmpty)
    }

    func testCorruptCatalogCannotBeOverwrittenByRepeatedMutations() throws {
        let library = try folder("library"), project = try folder("project")
        let catalog = library.appendingPathComponent("projects.json")
        try "not-json".write(to: catalog, atomically: true, encoding: .utf8)
        let store = ProjectKnowledgeStore(directory: library)
        XCTAssertNil(store.addProject(name: "First attempt", folder: project))
        XCTAssertNil(store.addProject(name: "Second attempt", folder: project))
        XCTAssertEqual(try String(contentsOf: catalog), "not-json")
    }

    func testQuerySyntaxIsTreatedAsLiteralWords() async throws {
        let project = try folder("project")
        try "status draft".write(to: project.appendingPathComponent("schema.sql"), atomically: true, encoding: .utf8)
        let store = ProjectKnowledgeStore(directory: directory.appendingPathComponent("library"))
        let id = try XCTUnwrap(store.addProject(name: "Project", folder: project))
        await store.reindex(id)
        XCTAssertFalse(store.search(projectID: id, query: "\"status\" OR (draft:*)").isEmpty)
        XCTAssertNil(store.errorMessage)
    }
}
