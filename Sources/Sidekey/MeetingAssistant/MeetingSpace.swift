import Foundation
import Darwin

// WHY: docs/decisions/2026-10-23-meeting-assistant-pilot.md
struct MeetingSpace: Codable, Equatable, Identifiable, Sendable {
    struct Source: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var kind: String
        var name: String
        var location: String?
        var connection_ref: String?
        var scope: [String]
        var access: String
    }
    var version: Int
    var id: String
    var name: String
    var purpose: String
    var instructions: String
    var sources: [Source]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whytap/meeting-spaces", isDirectory: true)
    }

    static func decode(_ data: Data, fileName: String) throws -> Self {
        func keys(_ value: Any?, allowed: Set<String>, required: Set<String>) throws {
            guard let object = value as? [String: Any], Set(object.keys).isSubset(of: allowed),
                  required.isSubset(of: Set(object.keys)) else { throw SpaceAccessError.invalid }
        }
        guard data.count <= 65_536 else { throw SpaceAccessError.invalid }
        let object = try JSONSerialization.jsonObject(with: data)
        let fields: Set<String> = ["version", "id", "name", "purpose", "instructions", "sources"]
        try keys(object, allowed: fields, required: fields)
        var value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, validID(value.id), fileName == value.id + ".json",
              !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.name.count <= 100, value.instructions.count <= 8_000, value.purpose.count <= 2_000,
              value.sources.count <= 100, Set(value.sources.map(\.id)).count == value.sources.count else { throw SpaceAccessError.invalid }
        for source in (object as? [String: Any])?["sources"] as? [Any] ?? [] {
            let locator = (source as? [String: Any])?["kind"] as? String == "repository" ? "location" : "connection_ref"
            let fields: Set<String> = ["id", "kind", "name", "scope", "access", locator]
            try keys(source, allowed: fields, required: fields)
        }
        for (index, source) in value.sources.enumerated() {
            guard validID(source.id), !source.name.isEmpty, source.access == "read",
                  !source.scope.isEmpty, source.scope.count <= 100 else { throw SpaceAccessError.invalid }
            if source.kind == "repository" {
                guard let location = source.location, location.hasPrefix("/"), source.connection_ref == nil else { throw SpaceAccessError.invalid }
                value.sources[index].location = try SpaceRepository.root(location, requireExists: false).path
                for scope in source.scope { _ = try SpaceRepository.components(scope, allowDot: true) }
            } else if source.kind == "database" {
                guard source.location == nil, let reference = source.connection_ref,
                      reference.range(of: "^(case|keychain|env)://[A-Za-z0-9_./-]+$", options: .regularExpression) != nil,
                      source.scope.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else { throw SpaceAccessError.invalid }
            } else { throw SpaceAccessError.invalid }
        }
        return value
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil
    }

    struct Catalog: Sendable { var spaces: [MeetingSpace]; var invalidFiles: [String] }
    static func load(directory: URL) throws -> Catalog {
        guard FileManager.default.fileExists(atPath: directory.path) else { return Catalog(spaces: [], invalidFiles: []) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        guard files.count <= 64 else { throw SpaceAccessError.invalid }
        var catalog = Catalog(spaces: [], invalidFiles: [])
        for file in files {
            do {
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 65_536 else { throw SpaceAccessError.invalid }
                let space = try decode(Data(contentsOf: file), fileName: file.lastPathComponent)
                guard !catalog.spaces.contains(where: { $0.id == space.id }) else { throw SpaceAccessError.invalid }
                catalog.spaces.append(space)
            } catch { catalog.invalidFiles.append(file.lastPathComponent) }
        }
        return catalog
    }
}

enum SpaceAccessError: Error, LocalizedError {
    case invalid, denied, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid: return "Некорректное описание Space. Попроси Codex или Claude Code проверить его."
        case .denied: return "Этот путь недоступен в выбранном Space."
        case .unavailable: return "Источник недоступен. Проверь папку или подключение Space."
        }
    }
}

/// Descriptor-relative reads reject symlinks at every level, including races
/// between a path check and open. Never expose the ordinary Agent's arbitrary
/// paths, shell, network, Case or write tools to meeting evidence.
struct SpaceRepository: Sendable {
    let source: MeetingSpace.Source

    static let excluded: Set<String> = ["node_modules", "build", "dist", "vendor", "Pods", "Library", "Caches"]
    static func allowed(_ part: String) -> Bool {
        let lower = part.lowercased()
        return !part.hasPrefix(".") && !excluded.contains(part)
            && !["credentials", "secrets", "id_rsa", "id_ed25519", "keychain", "keychains"].contains(lower)
            && ![".pem", ".p12", ".pfx", ".key", ".keychain-db", ".env"].contains(where: lower.hasSuffix)
            && !lower.contains("credentials.") && !lower.contains("secrets.")
    }
    static func components(_ path: String, allowDot: Bool = false) throws -> [String] {
        if allowDot && path == "." { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && allowed($0) && !$0.contains("\0") }) else { throw SpaceAccessError.denied }
        return parts
    }
    static func root(_ path: String, requireExists: Bool = true) throws -> URL {
        func canonical(_ path: String) -> URL? {
            guard let result = path.withCString({ realpath($0, nil) }) else { return nil }
            defer { free(result) }
            return URL(fileURLWithPath: String(cString: result))
        }
        guard path.hasPrefix("/"), !path.contains("\0") else { throw SpaceAccessError.denied }
        guard let value = canonical(path) ?? (requireExists ? nil : URL(fileURLWithPath: path).standardizedFileURL) else { throw SpaceAccessError.unavailable }
        let home = canonical(FileManager.default.homeDirectoryForCurrentUser.path) ?? FileManager.default.homeDirectoryForCurrentUser
        guard path.hasPrefix("/"), !path.contains("\0"), value.path != "/", value.path != home.path,
              !["/System", "/Library", "/private", "/Applications", "/Users"].contains(value.path),
              !value.lastPathComponent.hasPrefix("."),
              !["/System", "/Library", "/Applications", "/private/etc", "/private/var/db", "/dev"].contains(where: { value.path.hasPrefix($0 + "/") || value.path == $0 }),
              !value.path.hasPrefix(home.appendingPathComponent("Library").path + "/"),
              !value.pathComponents.dropFirst().contains(where: { [".ssh", ".aws", ".gnupg"].contains($0) }) else { throw SpaceAccessError.denied }
        return value
    }
    private func descriptor(_ path: String, directory: Bool) throws -> Int32 {
        guard let location = source.location else { throw SpaceAccessError.unavailable }
        let parts = try Self.components(path, allowDot: directory)
        let scopes = try source.scope.map { try Self.components($0, allowDot: true) }
        guard scopes.contains(where: { parts.starts(with: $0) || (directory && $0.starts(with: parts)) }) else { throw SpaceAccessError.denied }
        let base = try Self.root(location)
        guard base.path == location else { throw SpaceAccessError.denied }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw SpaceAccessError.unavailable }
        for component in base.pathComponents.dropFirst() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw SpaceAccessError.denied }
            fd = next
        }
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | ((directory || index < parts.count - 1) ? O_DIRECTORY : 0)
            let next = openat(fd, part, flags)
            Darwin.close(fd)
            guard next >= 0 else { throw SpaceAccessError.denied }
            fd = next
        }
        return fd
    }
    func read(_ path: String) throws -> String {
        let fd = try descriptor(path, directory: false)
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw SpaceAccessError.denied }
        var bytes = [UInt8](repeating: 0, count: 32_001)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count >= 0, !bytes.prefix(count).contains(0), let text = String(bytes: bytes.prefix(min(count, 32_000)), encoding: .utf8) else { throw SpaceAccessError.unavailable }
        return text.components(separatedBy: .newlines).enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
            + (count > 32_000 ? "\n[Файл сокращён]" : "")
    }
    func list(_ path: String = ".") throws -> [String] {
        let fd = try descriptor(path, directory: true)
        guard let dir = fdopendir(fd) else { Darwin.close(fd); throw SpaceAccessError.unavailable }
        defer { closedir(dir) }
        var results: [String] = []
        while let entry = readdir(dir) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard Self.allowed(name) else { continue }
            let relative = path == "." ? name : path + "/" + name
            let scopes = try source.scope.map { try Self.components($0, allowDot: true) }
            let parts = try Self.components(relative)
            guard scopes.contains(where: { parts.starts(with: $0) || $0.starts(with: parts) }) else { continue }
            var info = stat()
            guard fstatat(dirfd(dir), name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT != S_IFLNK else { continue }
            results.append(relative + (info.st_mode & S_IFMT == S_IFDIR ? "/" : ""))
            if results.count == 300 { break }
        }
        return results.sorted()
    }
    func search(_ query: String) throws -> String {
        guard !query.isEmpty, query.count <= 200 else { throw SpaceAccessError.invalid }
        var queue = ["."], visited = 0, matches: [String] = []
        while !queue.isEmpty, visited < 2000, matches.count < 40 {
            try Task.checkCancellation()
            let directory = queue.removeFirst()
            for item in (try? list(directory)) ?? [] {
                visited += 1
                if visited > 2000 || matches.count >= 40 { break }
                if item.hasSuffix("/") { queue.append(String(item.dropLast())); continue }
                if let text = try? read(item) {
                    for line in text.components(separatedBy: .newlines) where line.localizedCaseInsensitiveContains(query) {
                        matches.append("\(item):\(String(line.prefix(400)))")
                        if matches.count >= 40 { break }
                    }
                }
            }
        }
        return matches.isEmpty ? "Совпадений нет в доступной части Space." : matches.joined(separator: "\n")
    }
}
