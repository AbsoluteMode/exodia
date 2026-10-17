import AppKit
import XCTest
@testable import Sidekey

final class IslandHoverToolSearchTests: XCTestCase {
    func testFindsOutputLanguageWithoutPinningIt() {
        XCTAssertEqual(IslandHoverToolSearch.results(for: "output lang"), [.outputLang])
        XCTAssertEqual(IslandHoverToolSearch.results(for: "OUTPUT LANGUAGE"), [.outputLang])
    }

    func testMatchesAliasesAndMultiwordTermsAcrossCatalog() {
        XCTAssertEqual(IslandHoverToolSearch.results(for: "язык вывода"), [.outputLang])
        XCTAssertEqual(IslandHoverToolSearch.results(for: "clipboard"), [.clipboard])
        XCTAssertEqual(IslandHoverToolSearch.results(for: "server status").first, .monitor)
        XCTAssertTrue(IslandHoverToolSearch.results(for: "language").contains(.inputLang))
        XCTAssertTrue(IslandHoverToolSearch.results(for: "language").contains(.outputLang))
    }

    func testEmptyAndUnknownQueriesHaveNoResults() {
        XCTAssertFalse(IslandHoverToolSearch.isFiltering("  \n"))
        XCTAssertFalse(IslandHoverToolSearch.isFiltering("!"))
        XCTAssertTrue(IslandHoverToolSearch.results(for: "  \n").isEmpty)
        XCTAssertTrue(IslandHoverToolSearch.results(for: "doesnotexist").isEmpty)
    }

    func testTitleMatchRanksBeforeDescriptionMatchAndUsesEveryTerm() {
        XCTAssertEqual(IslandHoverToolSearch.results(for: "record").first, .meetingRecord)
        XCTAssertEqual(IslandHoverToolSearch.results(for: "input output"), [])
    }

    func testKeyboardSelectionWrapsAndHandlesEmptyResults() {
        XCTAssertEqual(IslandHoverToolSearch.nextSelection(current: 0, direction: -1, count: 3), 2)
        XCTAssertEqual(IslandHoverToolSearch.nextSelection(current: 2, direction: 1, count: 3), 0)
        XCTAssertEqual(IslandHoverToolSearch.nextSelection(current: 0, direction: 1, count: 1), 0)
        XCTAssertNil(IslandHoverToolSearch.nextSelection(current: 0, direction: 1, count: 0))
    }

    @MainActor
    func testGlassSearchCellPreservesNativeTextAndButtonInsets() throws {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let native = NSSearchField(frame: .zero)
            let transparent = IslandHoverSearchNativeField(frame: .zero)
            for field in [native, transparent] {
                field.font = NSFont.systemFont(ofSize: 12)
                field.stringValue = "output language"
            }
            let nativeCell = try XCTUnwrap(native.cell as? NSSearchFieldCell)
            let glassCell = try XCTUnwrap(transparent.cell as? IslandHoverSearchGlassCell)
            XCTAssertEqual(transparent.isBezeled, native.isBezeled)
            for width in [CGFloat(150), 320, 500] {
                let bounds = CGRect(x: 0, y: 0, width: width, height: IslandHoverToolSearch.fieldHeight)
                // Native search/cancel button geometry also reads the actual
                // control bounds, not only the rect passed to the cell method.
                for field in [native, transparent] {
                    field.frame = bounds
                    field.layoutSubtreeIfNeeded()
                }
                XCTAssertEqual(glassCell.searchTextRect(forBounds: bounds), nativeCell.searchTextRect(forBounds: bounds))
                XCTAssertEqual(glassCell.searchButtonRect(forBounds: bounds), nativeCell.searchButtonRect(forBounds: bounds))
                XCTAssertEqual(glassCell.cancelButtonRect(forBounds: bounds), nativeCell.cancelButtonRect(forBounds: bounds))
            }
            return
        }
        #endif
        throw XCTSkip("Native transparent search cell is used on macOS 26+")
    }

    @MainActor
    func testGlassSearchEditorStaysTransparentOnRepeatedEditingEntry() {
        let cell = IslandHoverSearchGlassCell(textCell: "output")
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 30))
        for _ in 0..<2 {
            // Simulate a shared field editor arriving with another field's paint.
            editor.drawsBackground = true
            editor.backgroundColor = .black
            let configured = cell.setUpFieldEditorAttributes(editor)
            XCTAssertTrue(configured === editor)
            XCTAssertFalse(editor.drawsBackground)
            XCTAssertEqual(editor.backgroundColor.alphaComponent, 0)
        }
    }

    @MainActor
    func testSearchingDoesNotChangeSavedLayoutOrPinnedSettings() {
        let suite = "IslandHoverToolSearchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HoverLayoutStore(defaults: defaults)
        store.replaceEditableSlots(with: [.monitor])
        let before = defaults.stringArray(forKey: HoverLayoutStore.defaultsKey)
        XCTAssertFalse(store.slots.contains(.outputLang))
        XCTAssertEqual(IslandHoverToolSearch.results(for: "output").first, .outputLang)
        XCTAssertEqual(store.slots, [.monitor, .settings])
        XCTAssertEqual(defaults.stringArray(forKey: HoverLayoutStore.defaultsKey), before)
        XCTAssertEqual(HoverSlotRouter.effect(for: .outputLang), .openPanel(.outputLanguagePicker))
    }
}
