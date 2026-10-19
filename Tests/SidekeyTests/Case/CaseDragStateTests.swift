import XCTest
@testable import Sidekey

final class CaseDragStateTests: XCTestCase {
    private func activeDrag() -> CaseDragState {
        var state = CaseDragState()
        state.begin(secretID: UUID(), sourceProjectID: UUID())
        state.dropTargetProjectID = UUID()
        return state
    }

    func testActiveDragScrollsNearEdges() {
        let state = activeDrag()
        XCTAssertLessThan(state.scrollVelocity(pointerY: 5, viewportHeight: 200), 0)
        XCTAssertGreaterThan(state.scrollVelocity(pointerY: 195, viewportHeight: 200), 0)
    }

    func testResetAfterBackgroundDropOrHoverEndStopsAutoScroll() {
        var state = activeDrag()
        state.reset()
        XCTAssertFalse(state.isDragging)
        XCTAssertNil(state.dropTargetProjectID)
        XCTAssertEqual(state.scrollVelocity(pointerY: 5, viewportHeight: 200), 0)
        XCTAssertEqual(state.scrollVelocity(pointerY: 195, viewportHeight: 200), 0)
    }

    func testFreshStateNeverScrolls() {
        XCTAssertEqual(CaseDragState().scrollVelocity(pointerY: 0, viewportHeight: 200), 0)
    }
}
