import XCTest
@testable import Sidekey

final class MacSwitchTests: XCTestCase {
    func testSlowDragSettlesOnNearestEndpointFromEitherState() {
        for initial in [true, false] {
            let travel = MacSwitch.Size.regular.travel
            let start = initial ? travel : 0
            for final in [-10.0, 0, 8, 13, 20, 40] {
                let translation = final - start
                XCTAssertEqual(MacSwitchInteraction.destination(startOn: initial, currentOn: initial, translation: translation,
                               predictedTranslation: translation, travel: travel), final > travel / 2)
            }
        }
    }

    func testQuickSwipeUsesDirectionAndDoesNotToggleAgain() {
        for initial in [true, false] {
            XCTAssertTrue(MacSwitchInteraction.destination(startOn: initial, currentOn: initial, translation: 3, predictedTranslation: 40, travel: 20))
            XCTAssertFalse(MacSwitchInteraction.destination(startOn: initial, currentOn: initial, translation: -3, predictedTranslation: -40, travel: 20))
        }
    }

    func testExternalStateChangeWinsOverAnInProgressDrag() {
        XCTAssertFalse(MacSwitchInteraction.destination(startOn: true, currentOn: false, translation: 40, predictedTranslation: 100, travel: 20))
        XCTAssertTrue(MacSwitchInteraction.destination(startOn: false, currentOn: true, translation: -40, predictedTranslation: -100, travel: 20))
    }

    func testCompactSwitchStillFitsIslandAndThumbStaysInsideTrack() {
        XCTAssertEqual(MacSwitch.Size.compact.track.width, 30)
        XCTAssertEqual(MacSwitch.Size.compact.track.height, 18)
        for size in [MacSwitch.Size.regular, .compact] {
            XCTAssertGreaterThan(size.travel, 0)
            XCTAssertEqual(size.inset * 2 + size.thumb.width + size.travel, size.track.width)
            XCTAssertEqual(size.inset * 2 + size.thumb.height, size.track.height)
        }
    }
}
