import XCTest
@testable import Sidekey

final class OpenCodeEnvironmentTests: XCTestCase {
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

    func test_without_catalog_declares_the_model_as_before() throws {
        let env = try OpenCodeEnvironment.make(workingDirectory: try temporaryDirectory(),
            model: "vendor/model", key: nil, allowActions: true, inherited: [:])
        let models = try declaredModels(env)
        let model = try XCTUnwrap(models["vendor/model"] as? [String: Any])
        XCTAssertTrue(model.isEmpty)
    }
}
