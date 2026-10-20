import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class IslandHoverMenuDismissTests: XCTestCase {
    func test_outside_click_passes_dismissal_geometry_and_bare_escape_only() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 310, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 310, height: 320))
        window.contentView = view
        let coordinator = IslandHoverMenuDismissObserver.Coordinator()
        coordinator.view = view
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            XCTAssertFalse(coordinator.shouldDismiss(event, at: window.convertPoint(toScreen: NSPoint(x: 100, y: 100))))
            XCTAssertTrue(coordinator.shouldDismiss(event, at: window.convertPoint(toScreen: NSPoint(x: -10, y: 100))))
        }
        for flags: NSEvent.ModifierFlags in [[], .command, .control, .option, .shift] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            XCTAssertEqual(coordinator.shouldDismiss(event), flags.isEmpty)
        }
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
    }
}
