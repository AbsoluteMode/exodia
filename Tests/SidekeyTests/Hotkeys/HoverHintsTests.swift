import XCTest
@testable import Sidekey

@MainActor
final class HoverHintsTests: XCTestCase {
    func test_help_lists_assigned_tools_by_name_even_when_unpinned() throws {
        var config = HotkeyConfiguration.defaults
        config.toolShortcuts = [.brightness: .combo(.optionD), .vocab: .combo(.optionFive)]
        let rows = HelpWindowContent.hotkeyRows(for: config)
        let display = try XCTUnwrap(rows.first { $0.title == "Tool — Display" })
        XCTAssertEqual(display.contents, HotkeyShortcut.combo(.optionD).contents)
        XCTAssertTrue(rows.contains { $0.title == "Tool — Vocab" })
        XCTAssertFalse(rows.contains { $0.title.hasPrefix("Hover slot") })
        XCTAssertFalse(rows.contains { $0.title == "Tool — Settings" })
        config.toolShortcuts[.brightness] = nil
        XCTAssertFalse(HelpWindowContent.hotkeyRows(for: config).contains { $0.title == "Tool — Display" })
    }

    func test_help_tool_hints_do_not_change_with_layout() {
        var config = HotkeyConfiguration.defaults
        config.toolShortcuts = [.settings: .combo(.optionPeriod)]
        let before = HelpWindowContent.hotkeyRows(for: config)
        let defaults = UserDefaults(suiteName: "SidekeyTests.HelpLayout.\(UUID().uuidString)")!
        let layout = HoverLayoutStore(defaults: defaults)
        layout.replaceEditableSlots(with: [.vocab, .brightness])
        XCTAssertEqual(before, HelpWindowContent.hotkeyRows(for: config))
    }

    func test_action_tools_do_not_expand_inline_panels() {
        for tool in [HoverTool.dropMode, .settings, .hotkeys, .notes, .quit, .meetingRecord] {
            XCTAssertFalse(HoverSlotRouter.effect(for: tool).requiresExpansion)
        }
        for tool in [HoverTool.clipboard, .vocab, .brightness, .outputLang, .monitor] {
            XCTAssertTrue(HoverSlotRouter.effect(for: tool).requiresExpansion)
        }
    }
}
