import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

final class IslandHoverHitBridgeTests: XCTestCase {
    private let frame = CGRect(x: 80, y: 120, width: 55, height: 72)
    private let center = CGPoint(x: 107, y: 156)

    private func target(owner: UUID = UUID(), tool: HoverTool = .outputLang,
                        context: String = "query:output", frame: CGRect? = nil) -> IslandHoverHitSnapshot {
        IslandHoverHitSnapshot(owner: owner, id: IslandHoverHitTargetID(surface: .result, tool: tool),
                               context: context, frame: frame ?? self.frame)
    }

    func testMatchingDownAndUpActivateExactlyOnce() {
        var tracking = IslandHoverPointerTracking()
        let result = target()
        XCTAssertTrue(tracking.begin(at: center, targets: [result], enabled: true))
        XCTAssertTrue(tracking.consumesSequence)
        XCTAssertEqual(tracking.captured?.id.tool, .outputLang)
        XCTAssertEqual(tracking.end(at: center, targets: [result], enabled: true), result.owner)
        XCTAssertFalse(tracking.consumesSequence)
        XCTAssertNil(tracking.end(at: center, targets: [result], enabled: true))
    }

    func testDraggingOutCancelsEvenIfPointerReturns() {
        var tracking = IslandHoverPointerTracking()
        let result = target()
        XCTAssertTrue(tracking.begin(at: center, targets: [result], enabled: true))
        tracking.move(at: CGPoint(x: 20, y: 20), targets: [result], enabled: true)
        XCTAssertNil(tracking.captured)
        XCTAssertTrue(tracking.consumesSequence, "A cancelled press still owns its mouse-up")
        tracking.move(at: center, targets: [result], enabled: true)
        XCTAssertNil(tracking.end(at: center, targets: [result], enabled: true))
    }

    func testUpOverDifferentToolNeverActivatesEitherTool() {
        var tracking = IslandHoverPointerTracking()
        let first = target()
        let other = target(tool: .monitor, frame: CGRect(x: 160, y: 120, width: 55, height: 72))
        XCTAssertTrue(tracking.begin(at: center, targets: [first, other], enabled: true))
        XCTAssertNil(tracking.end(at: CGPoint(x: 180, y: 155), targets: [first, other], enabled: true))
    }

    func testRemovedReplacedChangedOrMovedTargetCancelsPendingPress() {
        let original = target()
        let changedContext = target(owner: original.owner, context: "query:language")
        let replacement = target()
        let moved = target(owner: original.owner, frame: frame.offsetBy(dx: 0, dy: 5))
        for liveTargets in [[], [changedContext], [replacement], [moved]] {
            var tracking = IslandHoverPointerTracking()
            XCTAssertTrue(tracking.begin(at: center, targets: [original], enabled: true))
            XCTAssertNil(tracking.end(at: center, targets: liveTargets, enabled: true))
        }
    }

    func testClosedOrCancelledPanelCannotActivate() {
        let result = target()
        var tracking = IslandHoverPointerTracking()
        XCTAssertFalse(tracking.begin(at: center, targets: [result], enabled: false))
        XCTAssertFalse(tracking.begin(at: .zero, targets: [result], enabled: true))
        XCTAssertTrue(tracking.begin(at: center, targets: [result], enabled: true))
        XCTAssertNil(tracking.end(at: center, targets: [result], enabled: false))
        XCTAssertTrue(tracking.begin(at: center, targets: [result], enabled: true))
        tracking.cancel()
        XCTAssertNil(tracking.end(at: center, targets: [result], enabled: true))
        XCTAssertTrue(tracking.begin(at: center, targets: [result], enabled: true))
        tracking.discardSequence()
        XCTAssertFalse(tracking.consumesSequence)
        XCTAssertNil(tracking.end(at: center, targets: [result], enabled: true))
    }

    func testScrollViewportClipsRowsAwayFromSearchAndFooter() {
        let viewport = CGRect(x: 20, y: 50, width: 300, height: 100)
        let partiallyVisible = CGRect(x: 30, y: 30, width: 280, height: 42)
        let clipped = IslandHoverHitGeometry.visibleFrame(target: partiallyVisible,
            visible: partiallyVisible, region: viewport)
        XCTAssertEqual(clipped, CGRect(x: 30, y: 50, width: 280, height: 22))
        XCTAssertFalse(clipped!.contains(CGPoint(x: 80, y: 40)), "Footer must not activate a clipped row")
        XCTAssertNil(IslandHoverHitGeometry.visibleFrame(target: CGRect(x: 30, y: 160, width: 280, height: 42),
            visible: CGRect(x: 30, y: 160, width: 280, height: 42), region: viewport))
    }

    @MainActor
    func testInternalFieldEditingEndDoesNotResignBeforeButtonMouseUp() {
        var focusChanges: [Bool] = []
        let field = IslandHoverSearchField(text: .constant("output"),
            onFocusChange: { focusChanges.append($0) }, onCommand: { _ in })
        let coordinator = field.makeCoordinator()
        coordinator.controlTextDidBeginEditing(Notification(name: NSText.didBeginEditingNotification))
        coordinator.controlTextDidEndEditing(Notification(name: NSText.didEndEditingNotification))
        XCTAssertEqual(focusChanges, [true])
    }
}
