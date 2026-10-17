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
