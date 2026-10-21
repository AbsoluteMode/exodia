import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class ScreenshotUndoTests: XCTestCase {
    private func canvas() throws -> ScreenshotCanvas {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvas = ScreenshotCanvas(image: try XCTUnwrap(context.makeImage()), size: CGSize(width: 300, height: 200))
        canvas.selection = canvas.bounds
        return canvas
    }

    private func panel(canvas: ScreenshotCanvas, content: NSView) -> ScreenshotCapturePanel {
        let panel = ScreenshotCapturePanel(contentRect: CGRect(x: -20_000, y: -20_000, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.keyboardCanvas = canvas
        panel.contentView = content
        panel.makeFirstResponder(content)
        return panel
    }

    private func key(_ panel: NSWindow, characters: String, modifiers: NSEvent.ModifierFlags = .command,
                     keyCode: UInt16 = 6) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private func drawCurve(on canvas: ScreenshotCanvas, in panel: NSWindow) throws {
        let initialCount = canvas.annotations.count
        canvas.selectTool(.pen)
        for (type, point) in [(NSEvent.EventType.leftMouseDown, CGPoint(x: 30, y: 40)),
                              (.leftMouseDragged, CGPoint(x: 80, y: 140)),
                              (.leftMouseDragged, CGPoint(x: 150, y: 60)),
                              (.leftMouseUp, CGPoint(x: 230, y: 120))] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: canvas.mouseDragged(with: event)
            }
        }
        XCTAssertEqual(canvas.annotations.count, initialCount + 1)
        XCTAssertEqual(canvas.annotations.last?.tool, .pen)
        XCTAssertGreaterThan(canvas.annotations.last?.points.count ?? 0, 3)
    }

    func testCommandZAndRedoAfterDrawingCurveThroughWindowDispatch() throws {
        let canvas = try canvas()
        let panel = panel(canvas: canvas, content: canvas)
        defer { panel.contentView = nil; panel.close() }
        let first = ScreenshotAnnotation(tool: .arrow, points: [.zero, CGPoint(x: 10, y: 10)])
        canvas.commit(first)
        try drawCurve(on: canvas, in: panel)
        let points = try XCTUnwrap(canvas.annotations.last?.points)
        panel.sendEvent(try key(panel, characters: "z"))
        XCTAssertEqual(canvas.annotations.map(\.id), [first.id])
        XCTAssertEqual(canvas.selection, canvas.bounds)
        panel.sendEvent(try key(panel, characters: "Z", modifiers: [.command, .shift]))
        XCTAssertEqual(canvas.annotations.last?.points, points)
        panel.sendEvent(try key(panel, characters: "z"))
        XCTAssertEqual(canvas.annotations.map(\.id), [first.id], "One key press must perform exactly one undo")
    }

    func testRussianLayoutUndoAndRedoFromEachScreenshotPanel() throws {
        let canvas = try canvas()
        let panels = [panel(canvas: canvas, content: canvas), panel(canvas: canvas, content: NSView()),
                      panel(canvas: canvas, content: NSView())]
        defer { panels.forEach { $0.contentView = nil; $0.close() } }
        for panel in panels {
            let annotation = ScreenshotAnnotation(tool: .pen, points: [CGPoint(x: 20, y: 20), CGPoint(x: 90, y: 90)])
            canvas.commit(annotation)
            XCTAssertTrue(panel.performKeyEquivalent(with: try key(panel, characters: "я")))
            XCTAssertTrue(canvas.annotations.isEmpty)
            panel.sendEvent(try key(panel, characters: "Я", modifiers: [.command, .shift]))
            XCTAssertEqual(canvas.annotations.first?.id, annotation.id)
            panel.sendEvent(try key(panel, characters: "я"))
            XCTAssertTrue(canvas.annotations.isEmpty)
        }
    }

    func testCommandUndoDoesNotConsumeOtherModifierCombinationsOrRunWhileBusy() throws {
        let canvas = try canvas()
        let panel = panel(canvas: canvas, content: canvas)
        defer { panel.contentView = nil; panel.close() }
        canvas.commit(ScreenshotAnnotation(tool: .pen, points: [.zero, CGPoint(x: 90, y: 90)]))
        for modifiers: NSEvent.ModifierFlags in [[], [.command, .option], [.command, .control]] {
            panel.sendEvent(try key(panel, characters: "z", modifiers: modifiers))
            XCTAssertEqual(canvas.annotations.count, 1)
        }
        canvas.busy = true
        panel.sendEvent(try key(panel, characters: "я"))
        XCTAssertEqual(canvas.annotations.count, 1)
        canvas.busy = false
        panel.sendEvent(try key(panel, characters: "я"))
        XCTAssertTrue(canvas.annotations.isEmpty)
    }

    func testTextEditorKeepsCommandUndo() throws {
        let canvas = try canvas()
        let canvasPanel = panel(canvas: canvas, content: canvas)
        let editor = ScreenshotUndoTextView()
        let settings = panel(canvas: canvas, content: editor)
        defer { canvasPanel.contentView = nil; canvasPanel.close(); settings.contentView = nil; settings.close() }
        canvas.commit(ScreenshotAnnotation(tool: .pen, points: [.zero, CGPoint(x: 90, y: 90)]))
        XCTAssertTrue(settings.firstResponder === editor)
        for character in ["z", "я"] {
            let event = try key(settings, characters: character)
            XCTAssertFalse(settings.performKeyEquivalent(with: event))
            settings.sendEvent(event)
            XCTAssertEqual(canvas.annotations.count, 1)
        }
        XCTAssertEqual(editor.receivedKeys, ["z", "я"])
    }
}

@MainActor
private final class ScreenshotUndoTextView: NSTextView {
    var receivedKeys: [String] = []
    override func keyDown(with event: NSEvent) { receivedKeys.append(event.charactersIgnoringModifiers ?? "") }
}
