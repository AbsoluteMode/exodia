import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class MacSwitchAccessibilityTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var on = false
        @Published var enabled = true
    }
    private struct Harness: View {
        @ObservedObject var state: State
        var body: some View {
            MacSwitch(isOn: $state.on, isEnabled: state.enabled, label: "Meeting Notes").padding(12)
        }
    }

    func testNativeAccessibilitySwitchReadsAndChangesTheBinding() throws {
        let state = State()
        let host = NSHostingView(rootView: Harness(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 60)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 100, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        func find(_ node: Any) -> (any NSAccessibilityProtocol)? {
            guard let element = node as? any NSAccessibilityProtocol else { return nil }
            let role = element.accessibilityRole()?.rawValue
            if role == "AXCheckBox" || role == "AXSwitch" { return element }
            for child in element.accessibilityChildren() ?? [] {
                if let result = find(child) { return result }
            }
            return nil
        }
        let baseline = NSHostingView(rootView: Toggle("Baseline", isOn: .constant(false)).toggleStyle(.switch))
        baseline.frame = host.frame
        window.contentView = baseline
        baseline.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let nativeSwitchAvailable = find(baseline) != nil
        window.contentView = host
        settle()
        guard nativeSwitchAvailable else {
            throw XCTSkip("AppKit omits even the native Toggle from invisible-window AX trees; verify VoiceOver in the shared app")
        }
        let control = try XCTUnwrap(find(host), "The custom drawing must expose a native switch")
        XCTAssertEqual(control.accessibilityLabel(), "Meeting Notes")
        XCTAssertTrue(control.accessibilityPerformPress())
        settle()
        XCTAssertTrue(state.on)
        XCTAssertTrue(control.accessibilityPerformPress())
        settle()
        XCTAssertFalse(state.on)
        // A disabled switch exposes state but must refuse a user action.
        state.enabled = false
        settle()
        let disabled = try XCTUnwrap(find(host))
        _ = disabled.accessibilityPerformPress()
        settle()
        XCTAssertFalse(state.on)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
