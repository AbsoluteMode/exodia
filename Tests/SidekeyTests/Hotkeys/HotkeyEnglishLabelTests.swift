import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Sidekey

@MainActor
final class HotkeyEnglishLabelTests: XCTestCase {
    func testRussianLettersShowEnglishInLiveRecorderAndCommittedShortcut() throws {
        let keys: [(Int, String, String)] = [
            (kVK_ANSI_Q, "й", "Q"), (kVK_ANSI_W, "ц", "W"),
            (kVK_ANSI_E, "у", "E"), (kVK_ANSI_R, "к", "R"),
            (kVK_ANSI_T, "е", "T"), (kVK_ANSI_Y, "н", "Y"),
            (kVK_ANSI_U, "г", "U"), (kVK_ANSI_I, "ш", "I"),
            (kVK_ANSI_O, "щ", "O"), (kVK_ANSI_P, "з", "P"),
            (kVK_ANSI_A, "ф", "A"), (kVK_ANSI_S, "ы", "S"),
            (kVK_ANSI_D, "в", "D"), (kVK_ANSI_F, "а", "F"),
            (kVK_ANSI_G, "п", "G"), (kVK_ANSI_H, "р", "H"),
            (kVK_ANSI_J, "о", "J"), (kVK_ANSI_K, "л", "K"),
            (kVK_ANSI_L, "д", "L"), (kVK_ANSI_Z, "я", "Z"),
            (kVK_ANSI_X, "ч", "X"), (kVK_ANSI_C, "с", "C"),
            (kVK_ANSI_V, "м", "V"), (kVK_ANSI_B, "и", "B"),
            (kVK_ANSI_N, "т", "N"), (kVK_ANSI_M, "ь", "M")
        ]
        for (code, russian, english) in keys {
            var recorder = HotkeyShortcutRecorder()
            XCTAssertNil(recorder.record(try event(.keyDown, code, russian)))
            XCTAssertEqual(recorder.contents, [.text(english)])
            let shortcut = try XCTUnwrap(recorder.record(try event(.keyUp, code, russian)))
            XCTAssertEqual(shortcut.contents, [.text(english)])
            guard case .combo(let combo) = shortcut else { return XCTFail("Expected combo") }
            XCTAssertEqual(combo.keyCode, UInt32(code))
            XCTAssertEqual(combo.modifiers, 0)
        }
    }

    func testModifiedAndLegacyRecordersUseEnglishWithoutChangingModifiers() throws {
        let input = try event(.keyDown, kVK_ANSI_F, "А", flags: [.command, .shift])
        let combo = try XCTUnwrap(HotkeyTapCombo.recorded(from: input))
        XCTAssertEqual(combo.keyTitle, "F")
        XCTAssertEqual(combo.keyCode, UInt32(kVK_ANSI_F))
        XCTAssertEqual(combo.modifiers, UInt32(cmdKey) | UInt32(shiftKey))

        var recorder = HotkeyComboRecorder()
        XCTAssertEqual(recorder.record(try event(.keyDown, kVK_ANSI_F, "а", flags: [.option]))?.keyTitle, "F")
        XCTAssertEqual(recorder.contents, [.text(HotkeyGlyph.option), .text("F")])
    }

    func testOtherInputSourcesAndShiftedSymbolsKeepPhysicalEnglishLabels() throws {
        let keys: [(Int, String, String)] = [
            (kVK_ANSI_Q, "a", "Q"), (kVK_ANSI_Y, "z", "Y"),
            (kVK_ANSI_LeftBracket, "х", "["), (kVK_ANSI_RightBracket, "ъ", "]"),
            (kVK_ANSI_Semicolon, "ж", ";"), (kVK_ANSI_Quote, "э", "'"),
            (kVK_ANSI_Comma, "б", ","), (kVK_ANSI_Period, "ю", "."),
            (kVK_ANSI_Grave, "ё", "`"), (kVK_ANSI_Slash, ",", "/"),
            (kVK_ANSI_Backslash, "/", "\\"), (kVK_ANSI_3, "№", "3"),
            (kVK_ANSI_Minus, "_", "-"), (kVK_ANSI_Equal, "+", "=")
        ]
        for (code, character, expected) in keys {
            let combo = try XCTUnwrap(HotkeyTapCombo.recorded(from:
                event(.keyDown, code, character, flags: [.command, .shift])))
            XCTAssertEqual(combo.keyTitle, expected)
        }
    }

    func testExistingRussianScreenshotShortcutReloadsWithEnglishEverywhere() throws {
        let suite = "HotkeyEnglishLabelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = "{\"keyCode\":0,\"modifiers\":2048,\"keyTitle\":\"Ф\"}"
        defaults.set([HoverTool.screenshot.rawValue: raw], forKey: HotkeyPreferences.toolShortcutsDefaultsKey)
        let preferences = HotkeyPreferences(defaults: defaults)
        let shortcut = try XCTUnwrap(preferences.toolShortcuts[.screenshot])
        guard case .combo(let combo) = shortcut else { return XCTFail("Expected combo") }
        XCTAssertEqual(combo.keyCode, UInt32(kVK_ANSI_A))
        XCTAssertEqual(combo.modifiers, UInt32(optionKey))
        XCTAssertEqual(combo.keyTitle, "A")
        XCTAssertEqual(combo.shortcutChipTitles, [HotkeyGlyph.option, "A"])
        XCTAssertEqual(combo.compactToken, "opt a")
        XCTAssertEqual(HotkeyShortcutRecorder(shortcut: shortcut).contents, [.text(HotkeyGlyph.option), .text("A")])
        XCTAssertEqual(HotkeyHintView(contents: shortcut.contents).combinedAccessibilityLabel, "Option key, A key")
        let encoded = try JSONEncoder().encode(combo)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(saved["keyTitle"] as? String, "A")
    }

    func testUnknownKeysKeepStoredTitleAndNamedKeysStayReadable() throws {
        let unknown = HotkeyTapCombo(keyCode: 255, modifiers: UInt32(optionKey), keyTitle: "Custom")
        XCTAssertEqual(try JSONDecoder().decode(HotkeyTapCombo.self, from: JSONEncoder().encode(unknown)).keyTitle, "Custom")
        for (code, title) in [(kVK_F5, "F5"), (kVK_Space, "Space"), (kVK_Tab, "Tab"), (kVK_LeftArrow, "←")] {
            XCTAssertEqual(HotkeyTapCombo.recorded(from: try event(.keyDown, code, "", flags: [.option]))?.keyTitle, title)
        }
    }

    private func event(_ type: NSEvent.EventType, _ code: Int, _ characters: String,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
        ))
    }
}
