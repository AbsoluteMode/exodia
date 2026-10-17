import Combine
import Foundation
import SQLite3

struct KnowledgeProject: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var folder: URL
    var notes: String
    var indexedAt: Date?
    var indexedFiles: Int
}

struct ProjectKnowledgeMatch: Identifiable, Equatable {
    let path: String
    let firstLine: Int
    let lastLine: Int
    let text: String
    var id: String { "\(path):\(firstLine)" }
    var citation: String { "\(path):\(firstLine)-\(lastLine)" }
}

enum ProjectKnowledgeError: LocalizedError {
    case unavailable, tooLarge, invalidFolder
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Couldn’t open the local project library."
        case .tooLarge: return "This project exceeds the index limit (5,000 files or 32 MB of text). Choose a smaller folder. The previous index is preserved."
        case .invalidFolder: return "Choose an existing folder. Symbolic links are excluded."
        }
    }
}

/// Local lexical retrieval. Each operation uses its own SQLite connection;
/// readers see the previous complete snapshot while a reindex is committed.
final class ProjectKnowledgeIndex: @unchecked Sendable {
    let databaseURL: URL
    private let writer = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try withDatabase { db in
            try execute(db, "PRAGMA journal_mode=WAL")
            try execute(db, "CREATE VIRTUAL TABLE IF NOT EXISTS project_chunks USING fts5(project UNINDEXED, path UNINDEXED, first_line UNINDEXED, last_line UNINDEXED, body, tokenize='unicode61')")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    func replace(projectID: UUID, chunks: [ProjectKnowledgeMatch]) throws {
        writer.lock(); defer { writer.unlock() }
        try withDatabase { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try delete(db, projectID: projectID)
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO project_chunks VALUES (?, ?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { throw ProjectKnowledgeError.unavailable }
                defer { sqlite3_finalize(statement) }
                for chunk in chunks {
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    bind(projectID.uuidString, to: statement, at: 1)
                    bind(chunk.path, to: statement, at: 2)
                    sqlite3_bind_int(statement, 3, Int32(chunk.firstLine))
                    sqlite3_bind_int(statement, 4, Int32(chunk.lastLine))
                    bind(chunk.text, to: statement, at: 5)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw ProjectKnowledgeError.unavailable }
                }
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    func remove(projectID: UUID) throws {
        writer.lock(); defer { writer.unlock() }
        try withDatabase { db in try delete(db, projectID: projectID) }
    }

    func search(projectID: UUID, query: String, limit: Int = 6) throws -> [ProjectKnowledgeMatch] {
        let words = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }.prefix(20)
        guard !words.isEmpty else { return [] }
        // Quote each lexical term: user text never becomes FTS query syntax.
        let expression = words.map { "\"\($0)\"" }.joined(separator: " OR ")
        return try withDatabase { db in
            var statement: OpaquePointer?
            let sql = "SELECT path, first_line, last_line, body FROM project_chunks WHERE project_chunks MATCH ? AND project = ? ORDER BY bm25(project_chunks) LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ProjectKnowledgeError.unavailable }
            defer { sqlite3_finalize(statement) }
            bind(expression, to: statement, at: 1)
            bind(projectID.uuidString, to: statement, at: 2)
            sqlite3_bind_int(statement, 3, Int32(max(1, min(12, limit))))
            var result: [ProjectKnowledgeMatch] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    let path = String(cString: sqlite3_column_text(statement, 0))
                    let text = String(cString: sqlite3_column_text(statement, 3))
                    result.append(.init(path: path, firstLine: Int(sqlite3_column_int(statement, 1)),
                                        lastLine: Int(sqlite3_column_int(statement, 2)), text: text))
                case SQLITE_DONE: return result
                default: throw ProjectKnowledgeError.unavailable
                }
            }
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw ProjectKnowledgeError.unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        return try body(db)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ProjectKnowledgeError.unavailable }
    }
    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }
    private func delete(_ db: OpaquePointer, projectID: UUID) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM project_chunks WHERE project = ?", -1, &statement, nil) == SQLITE_OK else { throw ProjectKnowledgeError.unavailable }
        defer { sqlite3_finalize(statement) }
        bind(projectID.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProjectKnowledgeError.unavailable }
    }
}

enum ProjectKnowledgeScanner {
    static let extensions: Set<String> = ["md", "txt", "rst", "adoc", "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "kt", "cs", "c", "h", "cpp", "hpp", "rb", "php", "sql", "prisma", "graphql", "gql", "proto", "yaml", "yml", "json", "toml", "xml", "html", "css", "scss", "sh"]
    static let excludedDirectories: Set<String> = ["node_modules", "vendor", "build", "dist", "target", "coverage", "Pods", "DerivedData", "venv", "__pycache__"]

    static func scan(folder: URL) throws -> (chunks: [ProjectKnowledgeMatch], files: Int) {
        let manager = FileManager.default
        let root = folder.standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? root.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
              values.isSymbolicLink != true, root.resolvingSymlinksInPath().path == root.path else { throw ProjectKnowledgeError.invalidFolder }
        var failed = false
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                  errorHandler: { _, _ in failed = true; return false }) else { throw ProjectKnowledgeError.invalidFolder }
        var chunks: [ProjectKnowledgeMatch] = []
        var files = 0, bytes = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            let name = url.lastPathComponent.lowercased()
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_048_576,
                  extensions.contains(url.pathExtension.lowercased()),
                  !["secret", "credential", "password", "token", "id_rsa", "id_ed25519", "package-lock", "yarn.lock"].contains(where: name.contains) else { continue }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 1_048_576, !data.contains(0), let text = String(data: data, encoding: .utf8) else { continue }
            bytes += data.count; files += 1
            guard files <= 5_000, bytes <= 32 * 1_024 * 1_024 else { throw ProjectKnowledgeError.tooLarge }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let lines = text.components(separatedBy: .newlines)
            for start in stride(from: 0, to: lines.count, by: 32) {
                let end = min(start + 40, lines.count)
                let body = lines[start..<end].joined(separator: "\n")
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                chunks.append(.init(path: relative, firstLine: start + 1, lastLine: end,
                                    text: String(body.prefix(8_000))))
            }
        }
        guard !failed else { throw ProjectKnowledgeError.invalidFolder }
        return (chunks, files)
    }
}

@MainActor
final class ProjectKnowledgeStore: ObservableObject {
    static let shared = ProjectKnowledgeStore()
    @Published private(set) var projects: [KnowledgeProject] = []
    @Published private(set) var activeProjectID: UUID?
    @Published private(set) var indexingProjectID: UUID?
    @Published private(set) var errorMessage: String?
    private let catalogURL: URL
    private let index: ProjectKnowledgeIndex?
    private var generation = 0
    private var catalogReadable = true

    private struct Catalog: Codable {
        var projects: [KnowledgeProject]
        var activeProjectID: UUID?
    }

    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(BuildConfig.bundleID).appendingPathComponent("projects")
        catalogURL = directory.appendingPathComponent("projects.json")
        index = try? ProjectKnowledgeIndex(databaseURL: directory.appendingPathComponent("knowledge.sqlite"))
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            do {
                let saved = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
                projects = saved.projects
                activeProjectID = saved.projects.contains { $0.id == saved.activeProjectID } ? saved.activeProjectID : nil
            } catch {
                catalogReadable = false
                errorMessage = "Couldn’t read the project catalog. Its file has been preserved."
            }
        }
        if index == nil { errorMessage = ProjectKnowledgeError.unavailable.localizedDescription }
    }

    @discardableResult
    func addProject(name: String, folder: URL) -> UUID? {
        let folder = folder.standardizedFileURL
        if let existing = projects.first(where: { $0.folder == folder }) { return existing.id }
        let project = KnowledgeProject(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                       folder: folder, notes: "", indexedAt: nil, indexedFiles: 0)
        guard !project.name.isEmpty else { return nil }
        return mutate {
            projects.append(project)
            activeProjectID = project.id
        } ? project.id : nil
    }

    func selectProject(_ id: UUID?) {
        guard id == nil || projects.contains(where: { $0.id == id }) else { return }
        _ = mutate { activeProjectID = id }
    }

    func saveNotes(_ notes: String, projectID: UUID) {
        guard let position = projects.firstIndex(where: { $0.id == projectID }) else { return }
        _ = mutate { projects[position].notes = String(notes.prefix(48_000)) }
    }

    func removeProject(_ id: UUID) {
        guard indexingProjectID != id else { return }
        // Catalog first: failure to remove an orphan index must not expose its
        // evidence, because all retrieval requires a catalog project ID.
        guard mutate({
            projects.removeAll { $0.id == id }
            if activeProjectID == id { activeProjectID = nil }
        }) else { return }
        do { try index?.remove(projectID: id) }
        catch { errorMessage = "Project removed; its old index could not be cleaned up." }
    }

    func reindex(_ id: UUID) async {
        guard indexingProjectID == nil, let project = projects.first(where: { $0.id == id }), let index else { return }
        indexingProjectID = id
        generation += 1
        let run = generation
        defer { if run == generation { indexingProjectID = nil } }
        do {
            let result = try await Task.detached(priority: .utility) {
                let scan = try ProjectKnowledgeScanner.scan(folder: project.folder)
                try index.replace(projectID: id, chunks: scan.chunks)
                return scan.files
            }.value
            guard let position = projects.firstIndex(where: { $0.id == id }) else { return }
            _ = mutate {
                projects[position].indexedAt = Date()
                projects[position].indexedFiles = result
            }
        } catch { errorMessage = (error as? ProjectKnowledgeError)?.localizedDescription ?? "Couldn’t index the selected folder. The previous index is preserved." }
    }

    func search(projectID: UUID, query: String) -> [ProjectKnowledgeMatch] {
        guard projects.contains(where: { $0.id == projectID }) else { return [] }
        do { return try index?.search(projectID: projectID, query: query) ?? [] }
        catch { errorMessage = ProjectKnowledgeError.unavailable.localizedDescription; return [] }
    }

    func activeProjectContext(query: String) -> AgentProjectContext? {
        guard let project = projects.first(where: { $0.id == activeProjectID }) else { return nil }
        let matches = search(projectID: project.id, query: query)
        var excerpts: [String] = []
        if !project.notes.isEmpty { excerpts.append("Project notes (user supplied):\n\(project.notes)") }
        excerpts += matches.map { "Source: \($0.citation)\n\($0.text)" }
        if matches.isEmpty { excerpts.append("No indexed source matched this query. Do not infer missing schema facts.") }
        return AgentProjectContext(projectID: project.id, displayName: project.name,
                                   sourceExcerpts: String(excerpts.joined(separator: "\n\n").prefix(48_000)))
    }

    private func mutate(_ change: () -> Void) -> Bool {
        let previous = Catalog(projects: projects, activeProjectID: activeProjectID)
        change()
        do {
            // A corrupt existing catalog is never silently overwritten.
            guard catalogReadable else { throw ProjectKnowledgeError.unavailable }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Catalog(projects: projects, activeProjectID: activeProjectID))
            try data.write(to: catalogURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalogURL.path)
            errorMessage = nil
            return true
        } catch {
            projects = previous.projects; activeProjectID = previous.activeProjectID
            errorMessage = "Couldn’t save the local project catalog. No settings were changed."
            return false
        }
    }
}
