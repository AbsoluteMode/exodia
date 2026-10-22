import XCTest
@testable import Sidekey

final class OpenCodeEnvironmentTests: XCTestCase {
    func testScreenToolIsAvailableWithoutCaseOrCommandPermission() throws {
        let command = ["/Applications/Whytap.app/Contents/Helpers/whytap", "app", "screen-mcp"]
        let env = try OpenCodeEnvironment.make(workingDirectory: try temporaryDirectory(), model: "fixture/model",
            key: nil, allowActions: false, screenMCPCommand: command, inherited: [:])
        let json = try config(env)
        let mcp = try XCTUnwrap(json["mcp"] as? [String: [String: Any]])
        XCTAssertEqual(mcp["screen"]?["command"] as? [String], command)
        XCTAssertEqual(mcp["screen"]?["timeout"] as? Int, 15_000)
        XCTAssertNil(mcp["case"])
        let permission = try XCTUnwrap(json["permission"] as? [String: String])
        XCTAssertEqual(permission["*"], "deny")
        XCTAssertEqual(permission["screen_*"], "allow")
        XCTAssertEqual(permission["execute"], "allow")
        XCTAssertNil(permission["bash"])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func declaredModels(_ env: [String: String]) throws -> [String: Any] {
        let config = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let provider = try XCTUnwrap(json["provider"] as? [String: Any])
        let openrouter = try XCTUnwrap(provider["openrouter"] as? [String: Any])
        return try XCTUnwrap(openrouter["models"] as? [String: Any])
    }

    func test_declares_catalog_limits_for_the_model() throws {
        let spec = OpenCodeModelSpec(toolCall: true, reasoning: true, contextLimit: 1_000_000, outputLimit: 128_000)
        let env = try OpenCodeEnvironment.make(workingDirectory: try temporaryDirectory(),
            model: "anthropic/claude-sonnet-5.5", key: "k", allowActions: true, modelSpec: spec, inherited: [:])
        let models = try declaredModels(env)
        let model = try XCTUnwrap(models["anthropic/claude-sonnet-5.5"] as? [String: Any])
        let limit = try XCTUnwrap(model["limit"] as? [String: Int])
        XCTAssertEqual(limit["context"], 1_000_000)
        XCTAssertEqual(limit["output"], 128_000)
        XCTAssertEqual(model["tool_call"] as? Bool, true)
        XCTAssertEqual(model["reasoning"] as? Bool, true)
    }

    private func config(_ env: [String: String]) throws -> [String: Any] {
        let content = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"])
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    }

    /// A parent `ANTHROPIC_*` never reaches OpenCode: on an OpenRouter route it
    /// is dropped, on an Anthropic route the Keychain key replaces it.
    func test_inherited_anthropic_env_never_reaches_opencode() throws {
        let inherited = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "parent-anthropic",
                         "ANTHROPIC_BASE_URL": "https://proxy.example", "OPENROUTER_API_KEY": "parent-openrouter"]
        let openRouter = try OpenCodeEnvironment.make(workingDirectory: try temporaryDirectory(),
            model: "vendor/model", key: "or-keychain", allowActions: true, inherited: inherited)
        XCTAssertNil(openRouter["ANTHROPIC_API_KEY"])
        XCTAssertNil(openRouter["ANTHROPIC_BASE_URL"])
        XCTAssertEqual(openRouter["OPENROUTER_API_KEY"], "or-keychain")
        XCTAssertEqual(openRouter["PATH"], "/usr/bin")

        let anthropic = try OpenCodeEnvironment.make(workingDirectory: try temporaryDirectory(),
            model: "claude-sonnet-5-5", provider: .anthropic, key: "sk-ant-keychain", allowActions: true,
            inherited: inherited)
        XCTAssertEqual(anthropic["ANTHROPIC_API_KEY"], "sk-ant-keychain")
        XCTAssertNil(anthropic["ANTHROPIC_BASE_URL"])
        XCTAssertNil(anthropic["OPENROUTER_API_KEY"])
        XCTAssertEqual(anthropic["OPENCODE_DISABLE_CLAUDE_CODE"], "true")
    }

    func test_without_catalog_declares_the_model_as_before() throws {
        let env = try OpenCodeEnvironment.make(workingDirectory: try temporaryDirectory(),
            model: "vendor/model", key: nil, allowActions: true, inherited: [:])
        let models = try declaredModels(env)
        let model = try XCTUnwrap(models["vendor/model"] as? [String: Any])
        XCTAssertTrue(model.isEmpty)
    }
}
