import XCTest
@testable import Sidekey

@MainActor
final class IslandTileTitleTests: XCTestCase {
    func testMultiwordCapsuleTitlesPreserveSpacesWithoutForcedLineBreaks() {
        XCTAssertEqual(IslandHoverPanelControl.displayTitle("Input Language"), "Input Language")
        XCTAssertEqual(IslandHoverPanelControl.displayTitle("Drop Mode"), "Drop Mode")
        XCTAssertEqual(IslandHoverPanelControl.displayTitle("Output Language"), "Output Language")
    }

    func testCapsuleTitlesPreserveTheirOriginalCase() {
        XCTAssertEqual(IslandHoverPanelControl.displayTitle("Hotkeys"), "Hotkeys")
        XCTAssertEqual(IslandHoverPanelControl.displayTitle("Filler"), "Filler")
        XCTAssertEqual(IslandHoverPanelControl.displayTitle("Case"), "Case")
    }
}
