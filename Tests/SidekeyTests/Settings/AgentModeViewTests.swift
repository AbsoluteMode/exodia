import XCTest
@testable import Sidekey

@MainActor
final class AgentModeViewTests: XCTestCase {
    func test_agents_uses_mac_reskin_components() throws {
        let url = try projectRoot()
            .appendingPathComponent("Sources/Sidekey/Settings/AgentModeView.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.contains("MacCard"))
        XCTAssertTrue(s.contains("MacRow"))
        XCTAssertTrue(s.contains("MacButton"))
        XCTAssertTrue(s.contains("MacPill"))
    }

    func test_agents_uses_opencode_byok_setup_without_old_provider_chooser() throws {
        let url = try projectRoot()
            .appendingPathComponent("Sources/Sidekey/Settings/AgentModeView.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.contains("OpenCodeInstaller"))
        XCTAssertTrue(s.contains("OpenRouterLLMKeyStore"))
        XCTAssertTrue(s.contains("viewModel.connect(.opencode)"))
        XCTAssertFalse(s.contains("AgentSetupGuideView"))
    }

    func test_agents_exposes_capability_switch_for_disabled_hotkey_prompt() throws {
        let url = try projectRoot()
            .appendingPathComponent("Sources/Sidekey/Settings/AgentModeView.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.contains("Use Agent shortcuts"))
        XCTAssertTrue(s.contains("MacSwitch"))
        XCTAssertTrue(s.contains("onAgentToggle($0)"))
        XCTAssertTrue(s.contains("sidekeyCapabilityFlagsChanged"))
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "AgentModeViewTests", code: 1)
    }
}
