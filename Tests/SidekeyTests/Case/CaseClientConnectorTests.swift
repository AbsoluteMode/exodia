import XCTest
@testable import Sidekey

/// Client configs are the user's real files: every test here uses a temporary
/// HOME and a fake process runner, never ~/.claude.json, ~/.codex or ~/.cursor.
final class CaseClientConnectorTests: XCTestCase {
    private let helper = "/Applications/Whytap.app/Contents/Helpers/whytap"
    private let socket = "/Users/test/Library/Application Support/com.rootwise.sidekey/case-broker.sock"

    // MARK: Claude Code

    func test_claude_connector_runs_mcp_add_with_helper_path_and_no_secrets() throws {
        let home = try temporaryHome()
        let runner = FakeCommandRunner()
        let claude = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner, locate: { claude })

        try connector.install(helperPath: helper)

        XCTAssertEqual(runner.calls.count, 1, "nothing configured yet: a single add")
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.executable, claude)
        XCTAssertEqual(call.arguments, ["mcp", "add", "-s", "user", "case", "--", helper, "case", "mcp"])
        // The child gets only what it needs to find its own config, never a value or token.
        XCTAssertEqual(Set(call.environment.keys), ["HOME", "PATH", "LANG"])
        XCTAssertEqual(call.environment["HOME"], home.path)
        XCTAssertTrue(call.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") ?? false)
        let everything = (call.arguments + Array(call.environment.values)).joined(separator: " ")
        XCTAssertFalse(everything.contains("fixture-secret"))
        XCTAssertFalse(everything.localizedCaseInsensitiveContains("token"))
        // Without a sandboxed settings.json nothing else is written.
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }

    func test_claude_reinstall_replaces_existing_user_entry() throws {
        let home = try temporaryHome()
        try write(#"{"mcpServers":{"case":{"command":"/old/whytap","args":["case","mcp"]}}}"#,
                  to: home.appendingPathComponent(".claude.json"))
        let runner = FakeCommandRunner()
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        XCTAssertTrue(connector.isConfigured())

        try connector.install(helperPath: helper)

        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["mcp", "remove", "-s", "user", "case"],
            ["mcp", "add", "-s", "user", "case", "--", helper, "case", "mcp"],
        ])
    }

    func test_claude_sandbox_gets_socket_path_preserving_settings() throws {
        let home = try temporaryHome()
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let original = #"""
        {"model":"opus","permissions":{"allow":["Bash(ls:*)"]},
         "sandbox":{"enabled":true,"network":{"allowUnixSockets":["/tmp/other.sock"],"allowedDomains":["github.com"]}}}
        """#
        try write(original, to: settingsURL)
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: FakeCommandRunner(),
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })

        try connector.install(helperPath: helper)
        try connector.install(helperPath: helper) // idempotent

        let json = try readJSON(settingsURL)
        XCTAssertEqual(json["model"] as? String, "opus")
        XCTAssertEqual((json["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls:*)"])
        let sandbox = try XCTUnwrap(json["sandbox"] as? [String: Any])
        XCTAssertEqual(sandbox["enabled"] as? Bool, true)
        let network = try XCTUnwrap(sandbox["network"] as? [String: Any])
        XCTAssertEqual(network["allowUnixSockets"] as? [String], ["/tmp/other.sock", socket])
        XCTAssertEqual(network["allowedDomains"] as? [String], ["github.com"])
        // The previous file is kept next to it.
        XCTAssertEqual(try String(contentsOf: settingsURL.appendingPathExtension("bak"), encoding: .utf8), original)

        try connector.uninstall()
        let after = try readJSON(settingsURL)
        let afterNetwork = try XCTUnwrap((after["sandbox"] as? [String: Any])?["network"] as? [String: Any])
        XCTAssertEqual(afterNetwork["allowUnixSockets"] as? [String], ["/tmp/other.sock"])
    }

    func test_claude_sandbox_disabled_leaves_settings_untouched() throws {
        let home = try temporaryHome()
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let original = #"{"sandbox":{"enabled":false},"model":"opus"}"#
        try write(original, to: settingsURL)
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: FakeCommandRunner(),
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })

        try connector.install(helperPath: helper)

        XCTAssertEqual(try String(contentsOf: settingsURL, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.appendingPathExtension("bak").path))
    }

    func test_claude_broken_settings_are_not_overwritten() throws {
        let home = try temporaryHome()
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try write("{ not json", to: settingsURL)
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: FakeCommandRunner(),
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })

        XCTAssertThrowsError(try connector.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .unreadableConfig(".claude/settings.json"))
        }
        XCTAssertEqual(try String(contentsOf: settingsURL, encoding: .utf8), "{ not json")
    }

    func test_claude_missing_or_failing_cli_is_reported() throws {
        let home = try temporaryHome()
        let missing = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: FakeCommandRunner(), locate: { nil })
        XCTAssertFalse(missing.isInstalled())
        XCTAssertThrowsError(try missing.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .clientNotFound)
        }

        let runner = FakeCommandRunner()
        runner.status = 1
        let failing = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                              locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        XCTAssertThrowsError(try failing.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .commandFailed(status: 1))
        }

        let throwing = FakeCommandRunner()
        throwing.error = CaseClientConnectorError.timedOut
        let hanging = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: throwing,
                                              locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        XCTAssertThrowsError(try hanging.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .timedOut)
        }
    }

    func test_claude_uninstall_runs_remove_only_when_configured() throws {
        let home = try temporaryHome()
        let runner = FakeCommandRunner()
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        try connector.uninstall()
        XCTAssertTrue(runner.calls.isEmpty, "nothing to remove")

        try write(#"{"mcpServers":{"case":{},"other":{}}}"#, to: home.appendingPathComponent(".claude.json"))
        try connector.uninstall()
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "remove", "-s", "user", "case"]])
    }

    // MARK: Codex

    func test_codex_connector_adds_and_removes_without_touching_sandbox() throws {
        let home = try temporaryHome()
        let configURL = home.appendingPathComponent(".codex/config.toml")
        let config = "sandbox_mode = \"workspace-write\"\n"
        try write(config, to: configURL)
        let runner = FakeCommandRunner()
        let codex = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        let connector = CodexCaseConnector(home: home, runner: runner, locate: { codex })

        try connector.install(helperPath: helper)
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "add", "case", "--", helper, "case", "mcp"]])
        XCTAssertEqual(runner.calls.first?.executable, codex)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), config, "Codex config is changed only by codex itself")

        try write(config + "\n[mcp_servers.case]\ncommand = \"\(helper)\"\n", to: configURL)
        XCTAssertTrue(connector.isConfigured())
        runner.calls.removeAll()
        try connector.install(helperPath: helper)
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "remove", "case"],
                                                      ["mcp", "add", "case", "--", helper, "case", "mcp"]])
        runner.calls.removeAll()
        try connector.uninstall()
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "remove", "case"]])
    }

    // MARK: Cursor

    func test_cursor_connector_preserves_other_servers() throws {
        let home = try temporaryHome()
        let url = home.appendingPathComponent(".cursor/mcp.json")
        let original = #"{"mcpServers":{"github":{"command":"gh-mcp","args":["--stdio"],"env":{"X":"1"}}},"other":true}"#
        try write(original, to: url)
        let connector = CursorCaseConnector(home: home, appInstalled: { true })

        try connector.install(helperPath: helper)

        let json = try readJSON(url)
        XCTAssertEqual(json["other"] as? Bool, true)
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        let github = try XCTUnwrap(servers["github"] as? [String: Any])
        XCTAssertEqual(github["command"] as? String, "gh-mcp")
        XCTAssertEqual(github["args"] as? [String], ["--stdio"])
        XCTAssertEqual(github["env"] as? [String: String], ["X": "1"])
        let entry = try XCTUnwrap(servers["case"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, helper)
        XCTAssertEqual(entry["args"] as? [String], ["case", "mcp"])
        XCTAssertEqual(Set(entry.keys), ["command", "args"], "no env, no token")
        XCTAssertEqual(try String(contentsOf: url.appendingPathExtension("bak"), encoding: .utf8), original)
        XCTAssertTrue(connector.isConfigured())

        try connector.uninstall()
        let after = try readJSON(url)
        let afterServers = try XCTUnwrap(after["mcpServers"] as? [String: Any])
        XCTAssertNil(afterServers["case"])
        XCTAssertNotNil(afterServers["github"])
        XCTAssertEqual(after["other"] as? Bool, true)
    }

    func test_cursor_creates_missing_file_and_refuses_broken_one() throws {
        let home = try temporaryHome()
        let url = home.appendingPathComponent(".cursor/mcp.json")
        let connector = CursorCaseConnector(home: home, appInstalled: { false })
        XCTAssertFalse(connector.isInstalled())
        try connector.uninstall() // no file: nothing to do, nothing created
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try connector.install(helperPath: helper)
        let servers = try XCTUnwrap(try readJSON(url)["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["case"])

        try write("[1, 2", to: url)
        XCTAssertThrowsError(try connector.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .unreadableConfig(".cursor/mcp.json"))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[1, 2")
    }

    // MARK: CLI installer

    func test_cli_installer_refuses_to_replace_regular_file() throws {
        let home = try temporaryHome()
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let helperURL = home.appendingPathComponent("Whytap.app/Contents/Helpers/whytap")
        try write("#!/bin/sh\n", to: helperURL)
        try write("user's own script", to: bin.appendingPathComponent("whytap"))

        XCTAssertThrowsError(try CaseCLIInstaller.install(flavorName: "prod", helperURL: helperURL, binDir: bin)) { error in
            XCTAssertEqual(error as? CaseCLIInstallerError, .occupied(bin.appendingPathComponent("whytap").path))
        }
        XCTAssertEqual(try String(contentsOf: bin.appendingPathComponent("whytap"), encoding: .utf8), "user's own script")
    }

    func test_cli_installer_names_per_flavor_and_repoints_its_own_symlink() throws {
        let home = try temporaryHome()
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true) // does not exist yet
        let helperURL = home.appendingPathComponent("Whytap.app/Contents/Helpers/whytap")
        try write("#!/bin/sh\n", to: helperURL)

        XCTAssertEqual(try CaseCLIInstaller.commandName(flavorName: "prod"), "whytap")
        XCTAssertEqual(try CaseCLIInstaller.commandName(flavorName: "beta"), "whytap-beta")
        XCTAssertEqual(try CaseCLIInstaller.commandName(flavorName: "dev"), "whytap-dev")
        XCTAssertThrowsError(try CaseCLIInstaller.commandName(flavorName: "case"))

        let link = try CaseCLIInstaller.install(flavorName: "beta", helperURL: helperURL, binDir: bin)
        XCTAssertEqual(link.lastPathComponent, "whytap-beta")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), helperURL.path)

        // A stale link of ours (an older app location) is repointed.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Old/Whytap.app/Contents/Helpers/whytap")
        try CaseCLIInstaller.install(flavorName: "beta", helperURL: helperURL, binDir: bin)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), helperURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("whytap").path),
                       "beta never takes the prod name")

        // A directory with that name is not ours either.
        let dirBin = home.appendingPathComponent("bin2", isDirectory: true)
        try FileManager.default.createDirectory(at: dirBin.appendingPathComponent("whytap-dev"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try CaseCLIInstaller.install(flavorName: "dev", helperURL: helperURL, binDir: dirBin))
    }

    func test_cli_flavor_name_for_dev_builds() {
        XCTAssertEqual(CaseCLIInstaller.flavorName(flavor: .prod, allowsPackagedUpdates: true), "prod")
        XCTAssertEqual(CaseCLIInstaller.flavorName(flavor: .beta, allowsPackagedUpdates: true), "beta")
        XCTAssertEqual(CaseCLIInstaller.flavorName(flavor: .beta, allowsPackagedUpdates: false), "dev")
        XCTAssertEqual(CaseCLIInstaller.flavorName(flavor: .prod, allowsPackagedUpdates: false), "dev")
    }

    // MARK: Helpers

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("case-connector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

final class FakeCommandRunner: CaseCommandRunning {
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    var calls: [Call] = []
    var status: Int32 = 0
    var error: Error?

    func run(executable: URL, arguments: [String], environment: [String: String]) throws -> CaseCommandResult {
        calls.append(Call(executable: executable, arguments: arguments, environment: environment))
        if let error { throw error }
        return CaseCommandResult(status: status)
    }
}
