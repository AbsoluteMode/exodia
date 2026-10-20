// Tests/SidekeyTests/Settings/WhytapLinkTests.swift
import XCTest
@testable import Sidekey

final class WhytapLinkTests: XCTestCase {

    private func destination(_ string: String) -> WhytapLinkDestination? {
        guard let url = URL(string: string) else { return nil }
        return WhytapLink.destination(for: url)
    }

    // MARK: - Every tile and tab

    func test_every_tool_link_shows_the_place_its_tile_belongs_to() {
        for tool in HoverTool.allCases {
            let parsed = destination("whytap://tool/\(tool.rawValue)")
            XCTAssertEqual(parsed, WhytapLink.destination(for: tool), "\(tool)")

            switch HoverToolRegistry.info(for: tool).kind {
            case .inlinePanel:
                // Same panel as the tile click and its feature hotkey.
                guard case .openPanel(let panel) = HoverSlotRouter.effect(for: tool) else {
                    XCTFail("\(tool) is an inline panel without a panel effect")
                    continue
                }
                // Case asks for Touch ID on appear, so its link stops at Toolbox.
                let expected: WhytapLinkDestination = tool == .caseVault
                    ? .settings(.tab(.toolbox)) : .hoverPanel(panel)
                XCTAssertEqual(parsed, expected, "\(tool)")
            case .navigate(let target):
                XCTAssertEqual(parsed, .settings(target), "\(tool)")
            case .action:
                if case .hoverPanel = parsed { XCTFail("\(tool) action opened a hover panel") }
                XCTAssertNotEqual(parsed, .island, "\(tool) has no place")
            }
        }
    }

    func test_every_settings_link_opens_and_highlights_its_tab() {
        for tab in SettingsWindowTab.allCases {
            XCTAssertEqual(destination("whytap://settings/\(tab.rawValue)"), .settings(.tab(tab)), "\(tab)")
        }
    }

    func test_action_tools_show_their_place_without_running() {
        XCTAssertEqual(destination("whytap://tool/meetingRecord"), .toolboxTool(.meetingRecord))
        XCTAssertEqual(destination("whytap://tool/screenshot"), .toolboxTool(.screenshot))
        XCTAssertEqual(destination("whytap://tool/dropMode"), .toolboxTool(.dropMode))
        XCTAssertEqual(destination("whytap://tool/quit"), .settings(.quitRow))
        XCTAssertEqual(destination("whytap://tool/settings"), .settings(.tab(.apiAndModels)))
        XCTAssertEqual(destination("whytap://tool/tasks"), .planner(.tasks))
        XCTAssertEqual(destination("whytap://tool/calendar"), .planner(.calendar))
        XCTAssertEqual(destination("whytap://tool/translate"), .translation(.text))
        XCTAssertEqual(destination("whytap://tool/subtitles"), .translation(.subtitles))
    }

    // MARK: - Show only (Invariant 7)

    /// Every destination kind is reviewed as show-only. A new case does not
    /// compile here until someone classifies it.
    private func isShowOnly(_ destination: WhytapLinkDestination) -> Bool {
        switch destination {
        case .hoverPanel(let panel):
            // Case requests Touch ID when its panel appears.
            return panel != .caseVault
        case .toolboxTool(let tool):
            // Toolbox panes whose action is an explicit button. Case's pane
            // requests Touch ID on appear and is excluded.
            return [.dropMode, .meetingRecord, .screenshot].contains(tool)
        case .settings, .planner, .translation, .island:
            return true
        }
    }

    func test_no_link_runs_an_action_or_asks_for_authentication() {
        let destinations = HoverTool.allCases.map(WhytapLink.destination(for:))
            + SettingsWindowTab.allCases.map(WhytapLink.destination(for:))
        for destination in destinations {
            XCTAssertTrue(isShowOnly(destination), "\(destination)")
        }
    }

    func test_link_handler_never_calls_an_action() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Sidekey/AppDelegate.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func show(_ destination: WhytapLinkDestination)"))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ", options: .regularExpression)?.lowerBound ?? rest.endIndex
        let body = rest[..<end]
        for forbidden in ["invoke(", "actions.", "toggle", "quit", "Quit", "paste", "Pasteboard", "copy",
                          "record", "Record", "unlock", "openScreenshot", "start(", "terminate"] {
            XCTAssertFalse(body.contains(forbidden), "The whytap:// handler must only show places: found \(forbidden)")
        }
    }

    func test_scheme_and_kind_are_case_insensitive_but_ids_are_not() {
        XCTAssertEqual(destination("WHYTAP://Settings/agentMode"), .settings(.tab(.agentMode)))
        XCTAssertEqual(destination("whytap://settings/AGENTMODE"), .island)
    }

    // MARK: - Links from a newer site

    func test_unknown_ids_and_kinds_only_show_the_island() {
        XCTAssertEqual(destination("whytap://tool/someFutureTile"), .island)
        XCTAssertEqual(destination("whytap://settings/someFutureTab"), .island)
        XCTAssertEqual(destination("whytap://feature/notes"), .island)
    }

    func test_query_and_fragment_are_ignored() {
        XCTAssertEqual(destination("whytap://settings/backup?from=ask#top"), .settings(.tab(.backup)))
    }

    // MARK: - Rejected

    func test_other_schemes_are_rejected() {
        XCTAssertNil(destination("https://tool/notes"))
        XCTAssertNil(destination("whytapx://tool/notes"))
        XCTAssertNil(destination("file:///tool/notes"))
        XCTAssertNil(destination("exodia://settings/backup"))
    }

    func test_missing_kind_or_id_is_rejected() {
        XCTAssertNil(destination("whytap://"))
        XCTAssertNil(destination("whytap:tool/notes"))
        XCTAssertNil(destination("whytap:///notes"))
        XCTAssertNil(destination("whytap://tool"))
        XCTAssertNil(destination("whytap://tool/"))
        XCTAssertNil(destination("whytap://settings"))
    }

    func test_extra_segments_and_traversal_are_rejected() {
        XCTAssertNil(destination("whytap://tool/notes/"))
        XCTAssertNil(destination("whytap://tool/notes/extra"))
        XCTAssertNil(destination("whytap://tool//notes"))
        XCTAssertNil(destination("whytap://tool/.."))
        XCTAssertNil(destination("whytap://tool/../settings/backup"))
        XCTAssertNil(destination("whytap://settings/%2E%2E"))
        XCTAssertNil(destination("whytap://settings/backup%2Fother"))
        XCTAssertNil(destination("whytap://tool/.notes"))
    }

    func test_ids_outside_the_raw_value_alphabet_are_rejected() {
        XCTAssertNil(destination("whytap://tool/meeting-record"))
        XCTAssertNil(destination("whytap://tool/notes%00"))
        XCTAssertNil(destination("whytap://tool/n%C3%B6tes"))
        XCTAssertNil(destination("whytap://tool/" + String(repeating: "a", count: 65)))
    }

    func test_credentials_and_ports_are_rejected() {
        XCTAssertNil(destination("whytap://user@tool/notes"))
        XCTAssertNil(destination("whytap://user:secret@tool/notes"))
        XCTAssertNil(destination("whytap://tool:80/notes"))
    }

    // MARK: - Toolbox focus and registration

    @MainActor
    func test_toolbox_focus_selects_toolbox_and_carries_the_tool() {
        let selection = SettingsWindowSelection()
        selection.focus(HoverTool.meetingRecord)
        XCTAssertEqual(selection.selectedTab, .toolbox)
        XCTAssertEqual(selection.focusedTool, .meetingRecord)
    }

    func test_info_plist_registers_the_whytap_scheme() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Resources/Info.plist.template"),
                                encoding: .utf8)
        let pattern = "<key>CFBundleURLTypes</key>\\s*<array>\\s*<dict>[\\s\\S]*?"
            + "<key>CFBundleURLSchemes</key>\\s*<array>\\s*<string>whytap</string>"
        XCTAssertNotNil(source.range(of: pattern, options: .regularExpression))
    }
}
