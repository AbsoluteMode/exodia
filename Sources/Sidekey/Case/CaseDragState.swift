import CoreGraphics
import Foundation

/// Drag bookkeeping for the Case list. A drag that ends outside any project
/// row (released on empty space, cancelled) must not leave this set, or the
/// list keeps auto-scrolling on ordinary hover.
struct CaseDragState: Equatable {
    struct Context: Equatable {
        let secretID: UUID
        let sourceProjectID: UUID
    }

    var context: Context?
    var dropTargetProjectID: UUID?

    var isDragging: Bool { context != nil }

    mutating func begin(secretID: UUID, sourceProjectID: UUID) {
        context = Context(secretID: secretID, sourceProjectID: sourceProjectID)
    }

    mutating func reset() {
        context = nil
        dropTargetProjectID = nil
    }

    /// Auto-scroll velocity for the pointer; 0 whenever no drag is active.
    func scrollVelocity(pointerY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard isDragging else { return 0 }
        return CaseDragAutoScrollPolicy.velocity(pointerY: pointerY, viewportHeight: viewportHeight)
    }
}
