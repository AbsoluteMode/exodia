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

    func test_agents_model_subtitle_comes_from_the_route_not_a_hard_coded_provider() throws {
        let s = try source("Sources/Sidekey/Settings/AgentModeView.swift")
        XCTAssertTrue(s.contains("selectedOpenCodeModelLabel"))
        XCTAssertFalse(s.contains("\"OpenRouter ·"))
    }

    func test_settings_window_passes_the_api_and_models_callback() throws {
        let s = try source("Sources/Sidekey/Settings/SettingsWindowView.swift")
        XCTAssertTrue(s.contains("openAPIAndModels: { selection.focus($0) }"))
    }

    func test_opencode_hints_point_to_api_and_models() throws {
        let s = try source("Sources/Sidekey/Settings/SettingsWindowController.swift")
        XCTAssertTrue(s.contains("Install OpenCode in Settings → Agents, then press Connect."))
        XCTAssertTrue(s.contains("Add your OpenRouter key in Settings → API & Models, then press Connect."))
        let controller = try source("Sources/Sidekey/Agent/AgentController.swift")
        XCTAssertTrue(controller.contains("Connect Whytap Agent in Settings → Agents. Its model is set in API & Models."))
    }

    func test_no_user_facing_copy_still_names_the_models_tab() throws {
        let root = try projectRoot().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for file in files {
            let s = try String(contentsOf: file, encoding: .utf8)
            for stale in ["Settings → Models", "Settings -> Models", "Settings > Models"] {
                XCTAssertFalse(s.contains(stale), "\(file.lastPathComponent): \(stale)")
            }
        }
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

    private func source(_ path: String) throws -> String {
        try String(contentsOf: projectRoot().appendingPathComponent(path), encoding: .utf8)
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
