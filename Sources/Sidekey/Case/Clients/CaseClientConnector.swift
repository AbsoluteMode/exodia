import Foundation

/// Adds or removes the Case MCP server in one AI client's own settings.
/// Only the helper path goes into a client config: never a value or token.
protocol CaseClientConnector {
    var displayName: String { get }
    /// The client is present on this Mac (used to offer it for registration).
    func isInstalled() -> Bool
    /// Points the client's `case` MCP entry at `helperPath case mcp`;
    /// replaces an existing entry so a moved app is picked up.
    func install(helperPath: String) throws
    /// Removes the entry; nothing to remove is not an error.
    func uninstall() throws
}

enum CaseClientConnectorError: Error, Equatable {
    case clientNotFound
    case commandFailed(status: Int32)
    case timedOut
    /// Path relative to HOME; the file is left as it was.
    case unreadableConfig(String)
    case writeFailed(String)

    var userMessage: String {
        switch self {
        case .clientNotFound: return "программа не найдена"
        case .commandFailed(let status): return "команда завершилась с ошибкой (\(status))"
        case .timedOut: return "команда не ответила вовремя"
        case .unreadableConfig(let path): return "не удалось прочитать ~/\(path)"
        case .writeFailed(let path): return "не удалось записать ~/\(path)"
        }
    }
}

// MARK: Running client CLIs

struct CaseCommandResult: Equatable {
    let status: Int32
}

/// Seam for the client CLIs (`claude`, `codex`). Output is discarded: it is
/// never shown, stored or logged.
protocol CaseCommandRunning {
    func run(executable: URL, arguments: [String], environment: [String: String]) throws -> CaseCommandResult
}

struct SystemCaseCommandRunner: CaseCommandRunning {
    var timeout: TimeInterval = 30

    func run(executable: URL, arguments: [String], environment: [String: String]) throws -> CaseCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw CaseClientConnectorError.clientNotFound
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            throw CaseClientConnectorError.timedOut
        }
        return CaseCommandResult(status: process.terminationStatus)
    }
}

/// The minimal environment for a client CLI: enough to find its own config
/// and runtime (node next to an npm-installed `claude`), nothing inherited.
enum CaseClientEnvironment {
    static func make(home: URL, executable: URL) -> [String: String] {
        let standard = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let own = executable.deletingLastPathComponent().path
        let path = ([own] + standard.filter { $0 != own }).joined(separator: ":")
        return ["HOME": home.path, "PATH": path, "LANG": "en_US.UTF-8"]
    }
}

// MARK: JSON config files

/// Reads and rewrites a user's JSON config, keeping every other key. A file
/// that is not a JSON object is never overwritten. The previous file is kept
/// as `<name>.bak`; the new one replaces it atomically.
struct CaseJSONConfigFile {
    let home: URL
    /// Relative to HOME, e.g. `.cursor/mcp.json`.
    let relativePath: String

    var url: URL { home.appendingPathComponent(relativePath) }

    /// nil when the file does not exist.
    func read() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CaseClientConnectorError.unreadableConfig(relativePath) }
        return object
    }

    func write(_ object: [String: Any]) throws {
        let fm = FileManager.default
        do {
            let data = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = fm.fileExists(atPath: url.path)
            let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
            if existing {
                let backup = url.appendingPathExtension("bak")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: url, to: backup)
            }
            try (data + Data("\n".utf8)).write(to: url, options: .atomic)
            if let mode {
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            }
        } catch let error as CaseClientConnectorError {
            throw error
        } catch {
            throw CaseClientConnectorError.writeFailed(relativePath)
        }
    }
}

// MARK: Claude Code

/// `claude mcp add -s user case -- <helper> case mcp`. When Claude's sandbox is
/// on, the broker socket is added to `sandbox.network.allowUnixSockets`.
struct ClaudeCodeCaseConnector: CaseClientConnector {
    let displayName = "Claude Code"
    let home: URL
    let socketPath: String
    let runner: CaseCommandRunning
    let locate: () -> URL?

    init(home: URL, socketPath: String, runner: CaseCommandRunning = SystemCaseCommandRunner(),
         locate: @escaping () -> URL? = { ClaudeBinaryLocator().locate() }) {
        self.home = home
        self.socketPath = socketPath
        self.runner = runner
        self.locate = locate
    }

    private var settings: CaseJSONConfigFile { CaseJSONConfigFile(home: home, relativePath: ".claude/settings.json") }

    func isInstalled() -> Bool { locate() != nil }

    /// A user-scope `case` entry exists in `~/.claude.json` (read only).
    func isConfigured() -> Bool {
        let file = CaseJSONConfigFile(home: home, relativePath: ".claude.json")
        let servers = (try? file.read())??["mcpServers"] as? [String: Any]
        return servers?["case"] != nil
    }

    func install(helperPath: String) throws {
        // Read settings first: a broken file stops before anything changes.
        let current = try settings.read()
        let claude = try binary()
        if isConfigured() {
            try check(run(claude, ["mcp", "remove", "-s", "user", "case"]))
        }
        try check(run(claude, ["mcp", "add", "-s", "user", "case", "--", helperPath, "case", "mcp"]))
        try updateSandbox(current, adding: true)
    }

    func uninstall() throws {
        if isConfigured() {
            try check(run(try binary(), ["mcp", "remove", "-s", "user", "case"]))
        }
        try updateSandbox(try settings.read(), adding: false)
    }

    private func binary() throws -> URL {
        guard let url = locate() else { throw CaseClientConnectorError.clientNotFound }
        return url
    }

    private func run(_ binary: URL, _ arguments: [String]) throws -> CaseCommandResult {
        try runner.run(executable: binary, arguments: arguments,
                       environment: CaseClientEnvironment.make(home: home, executable: binary))
    }

    private func check(_ result: CaseCommandResult) throws {
        guard result.status == 0 else { throw CaseClientConnectorError.commandFailed(status: result.status) }
    }

    /// Only a sandbox that is explicitly enabled is touched.
    private func updateSandbox(_ current: [String: Any]?, adding: Bool) throws {
        guard var root = current,
              var sandbox = root["sandbox"] as? [String: Any],
              sandbox["enabled"] as? Bool == true
        else { return }
        var network = sandbox["network"] as? [String: Any] ?? [:]
        var sockets = network["allowUnixSockets"] as? [String] ?? []
        if adding {
            guard !sockets.contains(socketPath) else { return }
            sockets.append(socketPath)
        } else {
            guard sockets.contains(socketPath) else { return }
            sockets.removeAll { $0 == socketPath }
        }
        network["allowUnixSockets"] = sockets
        sandbox["network"] = network
        root["sandbox"] = sandbox
        try settings.write(root)
    }
}

// MARK: Codex

/// `codex mcp add case -- <helper> case mcp`. Codex's sandbox settings are
/// never changed; `config.toml` is written only by codex itself.
struct CodexCaseConnector: CaseClientConnector {
    let displayName = "Codex"
    let home: URL
    let runner: CaseCommandRunning
    let locate: () -> URL?

    init(home: URL, runner: CaseCommandRunning = SystemCaseCommandRunner(),
         locate: @escaping () -> URL? = { CodexBinaryLocator().locate() }) {
        self.home = home
        self.runner = runner
        self.locate = locate
    }

    func isInstalled() -> Bool { locate() != nil }

    func isConfigured() -> Bool {
        let url = home.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "[mcp_servers.case]" || trimmed == "[mcp_servers.\"case\"]"
        }
    }

    func install(helperPath: String) throws {
        guard let codex = locate() else { throw CaseClientConnectorError.clientNotFound }
        if isConfigured() {
            try check(run(codex, ["mcp", "remove", "case"]))
        }
        try check(run(codex, ["mcp", "add", "case", "--", helperPath, "case", "mcp"]))
    }

    func uninstall() throws {
        guard isConfigured() else { return }
        guard let codex = locate() else { throw CaseClientConnectorError.clientNotFound }
        try check(run(codex, ["mcp", "remove", "case"]))
    }

    private func run(_ binary: URL, _ arguments: [String]) throws -> CaseCommandResult {
        try runner.run(executable: binary, arguments: arguments,
                       environment: CaseClientEnvironment.make(home: home, executable: binary))
    }

    private func check(_ result: CaseCommandResult) throws {
        guard result.status == 0 else { throw CaseClientConnectorError.commandFailed(status: result.status) }
    }
}

// MARK: Cursor

/// `~/.cursor/mcp.json` → `mcpServers.case = {command, args}`.
struct CursorCaseConnector: CaseClientConnector {
    static let appPath = "/Applications/Cursor.app"

    let displayName = "Cursor"
    let home: URL
    let appInstalled: () -> Bool

    init(home: URL, appInstalled: @escaping () -> Bool = {
        FileManager.default.fileExists(atPath: CursorCaseConnector.appPath)
    }) {
        self.home = home
        self.appInstalled = appInstalled
    }

    private var file: CaseJSONConfigFile { CaseJSONConfigFile(home: home, relativePath: ".cursor/mcp.json") }

    func isInstalled() -> Bool { appInstalled() }

    func isConfigured() -> Bool {
        ((try? file.read())??["mcpServers"] as? [String: Any])?["case"] != nil
    }

    func install(helperPath: String) throws {
        var root = try file.read() ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["case"] = ["command": helperPath, "args": ["case", "mcp"]]
        root["mcpServers"] = servers
        try file.write(root)
    }

    func uninstall() throws {
        guard var root = try file.read(),
              var servers = root["mcpServers"] as? [String: Any],
              servers["case"] != nil
        else { return }
        servers["case"] = nil
        root["mcpServers"] = servers
        try file.write(root)
    }
}
