import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class ScreenshotReliabilityTests: XCTestCase {
    private func isolatedEnvironment() -> ScreenshotCaptureEnvironment {
        ScreenshotCaptureEnvironment(applicationNotifications: NotificationCenter(), workspaceNotifications: NotificationCenter(),
                                     frontmostApplication: { nil })
    }

    func testHoverKeepsItsExistingStateUntilPixelsAreFrozen() {
        XCTAssertTrue(IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: false, wasExpanded: true,
                                                  glance: false, screenshotPreparing: true))
        XCTAssertFalse(IslandView.mouseHoldsDrawer(pillHovering: true, panelHovering: true, wasExpanded: false,
                                                   glance: false, screenshotPreparing: true))
        XCTAssertFalse(IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: false, wasExpanded: true,
                                                   glance: false, screenshotPreparing: false))
    }

    func testDoubleClickDoesNotSelectFullDisplay() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvas = ScreenshotCanvas(image: try XCTUnwrap(context.makeImage()), size: CGSize(width: 100, height: 80))
        let window = ScreenshotCapturePanel(contentRect: CGRect(x: -20_000, y: -20_000, width: 100, height: 80), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = canvas; window.keyboardCanvas = canvas
        defer { window.contentView = nil; window.close() }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 40, y: 30), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
            type == .leftMouseDown ? canvas.mouseDown(with: event) : canvas.mouseUp(with: event)
        }
        XCTAssertTrue(canvas.selection.isEmpty)
        XCTAssertFalse(window.isVisible)
    }

    func testCaptureTimeoutReleasesActivityAndAllowsRetryEvenWhenProviderIgnoresCancellation() async throws {
        _ = NSApplication.shared
        var pending: [CheckedContinuation<[(NSScreen, CGImage)], Error>] = []
        var activity: [Bool] = [], requests = 0, failures: [String] = []
        let first = expectation(description: "First capture"), retry = expectation(description: "Retry capture")
        let timeout = expectation(description: "Capture deadline")
        let coordinator = ScreenshotCoordinator(activityChanged: { activity.append($0) }, captureOverride: {
            requests += 1
            return try await withCheckedThrowingContinuation {
                pending.append($0)
                (requests == 1 ? first : retry).fulfill()
            }
        }, captureTimeout: .milliseconds(50), captureFailure: {
            failures.append($0)
            if failures.count == 1 { timeout.fulfill() }
        }, environment: isolatedEnvironment())
        defer { coordinator.cancel(restoreFocus: false); pending.forEach { $0.resume(throwing: CancellationError()) } }
        coordinator.start()
        await fulfillment(of: [first, timeout], timeout: 2)
        XCTAssertFalse(coordinator.isActive); XCTAssertEqual(activity, [true, false])
        XCTAssertTrue(failures.first?.contains("too long") == true)
        coordinator.start()
        await fulfillment(of: [retry], timeout: 2)
        XCTAssertEqual(requests, 2)
    }

    func testRepeatedShortcutDoesNotCancelCaptureAndUnchangedDisplayNotificationIsIgnored() async throws {
        _ = NSApplication.shared
        var continuation: CheckedContinuation<[(NSScreen, CGImage)], Error>?
        var activity: [Bool] = [], preparing: [Bool] = []
        var requests = 0
        let started = expectation(description: "Capture requested")
        let environment = isolatedEnvironment()
        let coordinator = ScreenshotCoordinator(activityChanged: { activity.append($0) }, preparationChanged: { preparing.append($0) }, captureOverride: {
            requests += 1
            return try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
        }, environment: environment)
        coordinator.start()
        await fulfillment(of: [started], timeout: 2)
        coordinator.start(); coordinator.start()
        XCTAssertTrue(coordinator.isActive)
        XCTAssertEqual(requests, 1); XCTAssertEqual(preparing, [true])
        XCTAssertEqual(activity, [true], "Repeated hotkey events must not toggle capture off")
        environment.applicationNotifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(coordinator.isActive, "An unchanged display layout must not dismiss capture")
        environment.workspaceNotifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertFalse(coordinator.isActive, "The isolated Space notification still cancels a stale capture")
        continuation?.resume(throwing: CancellationError())
        await Task.yield()
        XCTAssertFalse(coordinator.isActive)
        XCTAssertEqual(activity, [true, false]); XCTAssertEqual(preparing, [true, false])
        coordinator.cancel(restoreFocus: false)
        XCTAssertEqual(preparing, [true, false], "Idle cancellation must not release/wake Hover again")
    }

    func testCommandZFromBothFloatingPanelsUndoesScreenshotEdits() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvas = ScreenshotCanvas(image: try XCTUnwrap(context.makeImage()), size: CGSize(width: 800, height: 400))
        canvas.selection = canvas.bounds
        let canvasWindow = ScreenshotCapturePanel(contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        canvasWindow.isReleasedWhenClosed = false; canvasWindow.contentView = canvas; canvasWindow.keyboardCanvas = canvas
        let toolbar = ScreenshotCapturePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        toolbar.isReleasedWhenClosed = false; toolbar.keyboardCanvas = canvas
        let settings = ScreenshotCapturePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        settings.isReleasedWhenClosed = false; settings.keyboardCanvas = canvas
        defer { canvasWindow.contentView = nil; canvasWindow.close(); toolbar.close(); settings.close() }
        func key(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        }
        let annotation = ScreenshotAnnotation(tool: .arrow, points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)])
        canvas.commit(annotation)
        XCTAssertTrue(toolbar.performKeyEquivalent(with: try key(.command)))
        XCTAssertTrue(canvas.annotations.isEmpty)
        XCTAssertTrue(settings.performKeyEquivalent(with: try key([.command, .shift])))
        XCTAssertEqual(canvas.annotations.first?.id, annotation.id)
        XCTAssertTrue(settings.performKeyEquivalent(with: try key(.command)))
        XCTAssertTrue(canvas.annotations.isEmpty)
        XCTAssertEqual(canvas.selection, canvas.bounds)
        var focusAdvances = 0
        canvasWindow.onAdvanceFocus = { _ in focusAdvances += 1 }
        for target in [canvasWindow, toolbar, settings] {
            for (characters, keyCode) in [(" ", UInt16(49)), ("x", 7), ("1", 18), ("s", 1), ("\t", 48)] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
                target.keyDown(with: event)
            }
        }
        XCTAssertEqual(focusAdvances, 3)
        XCTAssertTrue(canvas.annotations.isEmpty); XCTAssertEqual(canvas.selection, canvas.bounds)
        XCTAssertFalse(canvasWindow.isVisible); XCTAssertFalse(toolbar.isVisible); XCTAssertFalse(settings.isVisible)
    }

    func testSettingsStayBesideToolbarOnNegativeOriginDisplayAndAtScreenEdges() {
        let screen = CGRect(x: -800, y: -200, width: 800, height: 600)
        for bar in [CGRect(x: -790, y: -190, width: 640, height: 42), CGRect(x: -650, y: 345, width: 640, height: 42)] {
            let frame = ScreenshotGeometry.toolSettingsFrame(toolbar: bar, selection: CGRect(x: -700, y: 0, width: 100, height: 100),
                                                              screen: screen, size: CGSize(width: 280, height: 80))
            XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
            XCTAssertFalse(frame.intersects(bar))
        }
        let notched = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let bar = ScreenshotGeometry.toolbarFrame(selection: notched, screen: notched, size: CGSize(width: 740, height: 44), safeAreaTop: 32)
        let settings = ScreenshotGeometry.toolSettingsFrame(toolbar: bar, selection: notched, screen: notched,
                                                              size: CGSize(width: 280, height: 80), safeAreaTop: 32)
        XCTAssertLessThanOrEqual(bar.maxY, notched.maxY - 40)
        XCTAssertLessThanOrEqual(settings.maxY, notched.maxY - 40)
    }

    func testButtonsShowHoverAndPressedFeedbackAndSuppressDisabledHover() throws {
        _ = NSApplication.shared
        let button = ScreenshotToolbarButton(title: "Copy & exit", target: nil, action: nil)
        button.bezelStyle = .inline; button.isBordered = false
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 160, height: 32), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = button
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.contentView = nil; window.close() }
        func pixels() throws -> Data {
            button.displayIfNeeded()
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let idle = try pixels()
        button.mouseEntered(with: event)
        let hovered = try pixels()
        XCTAssertNotEqual(hovered, idle)
        button.highlight(true)
        XCTAssertNotEqual(try pixels(), hovered)
        button.highlight(false); button.isEnabled = false
        let disabledHovered = try pixels()
        button.mouseExited(with: event)
        XCTAssertEqual(try pixels(), disabledHovered, "Disabled controls must not respond to hover")
    }

    func testPrimaryCopyButtonKeepsAccentInNonKeyWindowInBothAppearances() throws {
        _ = NSApplication.shared
        let button = ScreenshotToolbarButton(title: "Copy & exit", target: nil, action: nil)
        button.isPrimaryAction = true; button.showsReturnKeycap = true
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 160, height: 32), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = button
        defer { window.contentView = nil; window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            button.layoutSubtreeIfNeeded()
            let hint = try XCTUnwrap(button.subviews.first { $0.identifier?.rawValue == "screenshot.return-keycap" })
            XCTAssertEqual(hint.frame.midY, button.bounds.midY, accuracy: 0.5)
            XCTAssertTrue(button.bounds.contains(hint.frame))
            XCTAssertNil(hint.hitTest(CGPoint(x: hint.bounds.midX, y: hint.bounds.midY)), "The keycap must preserve the button's full click area")
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(4 * CGFloat(bitmap.pixelsWide) / button.bounds.width), y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            var accent = NSColor.clear
            button.effectiveAppearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)! }
            XCTAssertEqual(color.redComponent, accent.redComponent, accuracy: 0.02)
            XCTAssertEqual(color.greenComponent, accent.greenComponent, accuracy: 0.02)
            XCTAssertEqual(color.blueComponent, accent.blueComponent, accuracy: 0.02)
            XCTAssertFalse(window.isKeyWindow)
        }
    }
}
