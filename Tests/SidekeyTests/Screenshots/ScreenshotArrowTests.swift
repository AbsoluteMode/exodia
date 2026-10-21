import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class ScreenshotArrowTests: XCTestCase {
    func testDropReplacesOnlyDestinationAndRejectsUnknownOrMultiplePayloads() {
        var bindings = ScreenshotArrowBindings.defaults
        XCTAssertEqual(bindings[.up], .blur); XCTAssertEqual(bindings[.down], .text)
        XCTAssertEqual(bindings[.left], .rectangle); XCTAssertEqual(bindings[.right], .pen)
        XCTAssertTrue(bindings.replace(.right, with: [bindings[.up].dragPayload]))
        XCTAssertEqual(bindings[.right], .blur); XCTAssertEqual(bindings[.up], .blur)
        XCTAssertEqual(bindings[.down], .text); XCTAssertEqual(bindings[.left], .rectangle)
        let before = bindings
        for payloads in [[], ["external text"], ["whytap.screenshot.action:unknown"],
                         [ScreenshotEditorAction.undo.dragPayload, ScreenshotEditorAction.redo.dragPayload]] {
            XCTAssertFalse(bindings.replace(.left, with: payloads)); XCTAssertEqual(bindings, before)
        }
        for action in ScreenshotEditorAction.allCases {
            XCTAssertTrue(bindings.replace(.up, with: [action.dragPayload])); XCTAssertEqual(bindings[.up], action)
        }
    }

    func testPersistenceSaveRevertResetAndHelpUseSameBindings() throws {
        let suite = "ScreenshotArrows.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = HotkeyPreferences(defaults: defaults)
        var draft = prefs.configuration
        draft.screenshotArrowBindings[.up] = .share
        XCTAssertEqual(prefs.configuration.screenshotArrowBindings[.up], .blur, "Drafts do not change the running editor before Save")
        try prefs.apply(draft)
        let restored = HotkeyPreferences(defaults: defaults)
        XCTAssertEqual(restored.configuration.screenshotArrowBindings[.up], .share)
        let backup = try ConfigBackupRegistry.capture(defaults)
        XCTAssertNotNil(backup[HotkeyPreferences.screenshotArrowsDefaultsKey])
        try ConfigBackupRegistry.validate(backup)
        XCTAssertTrue(HelpWindowContent.hotkeyRows(for: restored.configuration).contains {
            $0.title == "Screenshot — ↑" && $0.detail.contains("Share")
        })
        prefs.resetToDefaults()
        XCTAssertEqual(prefs.screenshotArrowBindings, .defaults)
        XCTAssertEqual(ScreenshotArrowBindings(saved: ["up": "unknown", "bogus": "copy"]), .defaults)
    }

    func testAllActionsDispatchThroughEachFloatingPanelAndModifiedArrowsStillAdjustCrop() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var bindings = ScreenshotArrowBindings.defaults
        let canvas = ScreenshotCanvas(image: try XCTUnwrap(context.makeImage()), size: CGSize(width: 300, height: 200), arrowBindings: { bindings })
        let crop = CGRect(x: 20, y: 20, width: 200, height: 100)
        canvas.selection = crop
        let panels = (0..<3).map { index -> ScreenshotCapturePanel in
            let panel = ScreenshotCapturePanel(contentRect: CGRect(x: -20_000, y: -20_000, width: 300, height: 200),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isReleasedWhenClosed = false; panel.keyboardCanvas = canvas
            panel.contentView = index == 0 ? canvas : NSView(frame: canvas.bounds)
            panel.makeFirstResponder(panel.contentView)
            return panel
        }
        defer { panels.forEach { $0.contentView = nil; $0.close() } }
        func send(_ arrow: ScreenshotArrow, to panel: NSWindow, modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: arrow.keyCode))
            panel.sendEvent(event)
        }
        var commands: [ScreenshotCommand] = []
        canvas.onCommand = { commands.append($0) }
        for panel in panels {
            bindings[.up] = .pen; bindings[.down] = .blur; bindings[.left] = .undo; bindings[.right] = .copy
            try send(.up, to: panel); XCTAssertEqual(canvas.tool, .pen)
            try send(.down, to: panel); XCTAssertEqual(canvas.tool, .blur)
            for action in ScreenshotEditorAction.allCases where action.tool != nil {
                bindings[.up] = action
                try send(.up, to: panel); XCTAssertEqual(canvas.tool, action.tool)
            }
            for (action, command) in [(ScreenshotEditorAction.copy, ScreenshotCommand.copy), (.copyText, .copyText), (.download, .download), (.share, .share), (.cancel, .cancel)] {
                bindings[.right] = action
                try send(.right, to: panel); XCTAssertEqual(commands.last, command)
                let count = commands.count
                try send(.right, to: panel, repeatKey: true); XCTAssertEqual(commands.count, count)
            }
            canvas.commit(ScreenshotAnnotation(tool: .pen, points: [.zero, CGPoint(x: 30, y: 30)]))
            try send(.left, to: panel); XCTAssertTrue(canvas.annotations.isEmpty)
            bindings[.right] = .redo
            try send(.right, to: panel); XCTAssertEqual(canvas.annotations.count, 1)
            bindings[.right] = .deleteAnnotation
            // Redo clears selection, so select a newly committed annotation to delete.
            canvas.commit(ScreenshotAnnotation(tool: .arrow, points: [.zero, CGPoint(x: 50, y: 50)]))
            try send(.right, to: panel); XCTAssertEqual(canvas.annotations.count, 1)
            canvas.annotations = []
            canvas.selection = crop
            try send(.right, to: panel, modifiers: .shift); XCTAssertEqual(canvas.selection.minX, crop.minX + 10)
            try send(.up, to: panel, modifiers: .option); XCTAssertEqual(canvas.selection.height, crop.height + 1)
            canvas.selection = crop
            bindings[.right] = .moveCrop
            try send(.right, to: panel); XCTAssertEqual(canvas.selection.minX, crop.minX + 1)
            canvas.selection = crop
            bindings = .defaults
        }
        let text = ArrowTextView()
        panels[2].contentView = text; panels[2].makeFirstResponder(text)
        for arrow in ScreenshotArrow.allCases { try send(arrow, to: panels[2]) }
        XCTAssertEqual(text.keyCodes, ScreenshotArrow.allCases.map(\.keyCode))
        canvas.busy = true; bindings[.right] = .cancel
        try send(.right, to: panels[0]); XCTAssertEqual(commands.last, .cancel)
        XCTAssertTrue(panels.allSatisfy { !$0.isVisible })
    }


}

@MainActor
private final class ArrowTextView: NSTextView {
    var keyCodes: [UInt16] = []
    override func keyDown(with event: NSEvent) { keyCodes.append(event.keyCode) }
}
