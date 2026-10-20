import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class ScreenshotSelectionTests: XCTestCase {
    func testClickingExistingBlurPreservesCropAndDeleteRemovesOnlyBlur() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 400,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let canvas = ScreenshotCanvas(image: image, size: CGSize(width: 800, height: 400))
        let window = ScreenshotCapturePanel(contentRect: CGRect(x: -20_000, y: -20_000, width: 800, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        let crop = CGRect(x: 20, y: 20, width: 740, height: 360)
        canvas.selection = crop
        canvas.commit(ScreenshotAnnotation(tool: .blur,
            points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200)], patch: image))
        canvas.selectTool(.select)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 200, y: 150),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try mouse(.leftMouseDown))
        XCTAssertEqual(canvas.message, "Blur selected · Delete to remove, or ⌘Z to undo")
        canvas.mouseUp(with: try mouse(.leftMouseUp))
        XCTAssertEqual(canvas.selection, crop, "Selecting a blur must not clear the crop or hide the export toolbar")
        XCTAssertEqual(canvas.annotations.count, 1)
        let delete = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false, keyCode: 51))
        canvas.keyDown(with: delete)
        XCTAssertTrue(canvas.annotations.isEmpty)
        XCTAssertEqual(canvas.selection, crop)
        canvas.undo()
        XCTAssertEqual(canvas.annotations.count, 1); XCTAssertEqual(canvas.selection, crop)
        canvas.redo()
        XCTAssertTrue(canvas.annotations.isEmpty); XCTAssertEqual(canvas.selection, crop)
        XCTAssertFalse(window.isVisible)
    }

    func testDraggingBlurLeavesPatchAndCropFixedAndAddsNoUndoStep() throws {
        try withCanvas { canvas, window, crop, patch in
            let annotation = try XCTUnwrap(canvas.annotations.first)
            try drag(canvas, window: window, from: CGPoint(x: 200, y: 150), to: CGPoint(x: 650, y: 340))
            XCTAssertEqual(canvas.selection, crop)
            XCTAssertEqual(canvas.annotations[0].id, annotation.id)
            XCTAssertEqual(canvas.annotations[0].points, annotation.points)
            XCTAssertTrue(canvas.annotations[0].patch === patch)
            let exported = try ScreenshotRenderer.image(source: canvas.source, size: canvas.documentSize,
                                                         annotations: canvas.annotations, crop: canvas.selection)
            XCTAssertEqual(exported.width, 740); XCTAssertEqual(exported.height, 360)
            // The first Undo must remove the actual blur, not undo a selection-only drag.
            canvas.undo(); XCTAssertTrue(canvas.annotations.isEmpty); XCTAssertEqual(canvas.selection, crop)
            canvas.redo(); XCTAssertEqual(canvas.annotations.count, 1); XCTAssertEqual(canvas.selection, crop)
            XCTAssertEqual(canvas.annotations[0].points, annotation.points)
        }
    }

    func testSelectingBlurPreservesPendingRedoAndNormalAnnotationMovement() throws {
        try withCanvas { canvas, window, crop, _ in
            let rectangle = ScreenshotAnnotation(tool: .rectangle, points: [CGPoint(x: 400, y: 100), CGPoint(x: 500, y: 200)])
            canvas.commit(rectangle); canvas.undo()
            XCTAssertTrue(canvas.canRedo)
            try drag(canvas, window: window, from: CGPoint(x: 200, y: 150), to: CGPoint(x: 200, y: 150))
            XCTAssertTrue(canvas.canRedo)
            canvas.redo(); XCTAssertEqual(canvas.annotations.count, 2); XCTAssertEqual(canvas.selection, crop)
            try drag(canvas, window: window, from: CGPoint(x: 450, y: 150), to: CGPoint(x: 480, y: 160))
            XCTAssertEqual(canvas.selection, crop)
            XCTAssertEqual(canvas.annotations[1].points, [CGPoint(x: 430, y: 110), CGPoint(x: 530, y: 210)])
            canvas.undo(); XCTAssertEqual(canvas.annotations[1].points, rectangle.points)
        }
    }

    func testCropMoveResizeAndReplacementStillWorkAfterSelectingBlur() throws {
        try withCanvas { canvas, window, crop, _ in
            let blurPoints = try XCTUnwrap(canvas.annotations.first).points
            try drag(canvas, window: window, from: CGPoint(x: 200, y: 150), to: CGPoint(x: 200, y: 150))
            try drag(canvas, window: window, from: CGPoint(x: 700, y: 300), to: CGPoint(x: 710, y: 305))
            XCTAssertEqual(canvas.selection, crop.offsetBy(dx: 10, dy: 5))
            canvas.undo(); XCTAssertEqual(canvas.selection, crop)
            try drag(canvas, window: window, from: crop.origin, to: CGPoint(x: 30, y: 30))
            XCTAssertEqual(canvas.selection, CGRect(x: 30, y: 30, width: 730, height: 350))
            canvas.undo(); XCTAssertEqual(canvas.selection, crop)
            canvas.redo(); XCTAssertEqual(canvas.selection, CGRect(x: 30, y: 30, width: 730, height: 350))
            // A new crop starts only outside the existing selection, as before.
            try drag(canvas, window: window, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 780, y: 390))
            XCTAssertEqual(canvas.selection, CGRect(x: 5, y: 5, width: 775, height: 385))
            XCTAssertEqual(canvas.annotations[0].points, blurPoints)
            canvas.undo(); XCTAssertEqual(canvas.selection, CGRect(x: 30, y: 30, width: 730, height: 350))
            canvas.redo(); XCTAssertEqual(canvas.selection, CGRect(x: 5, y: 5, width: 775, height: 385))
        }
    }

    private func withCanvas(_ body: (ScreenshotCanvas, ScreenshotCapturePanel, CGRect, CGImage) throws -> Void) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let canvas = ScreenshotCanvas(image: image, size: CGSize(width: 800, height: 400))
        let window = ScreenshotCapturePanel(contentRect: CGRect(x: -20_000, y: -20_000, width: 800, height: 400),
                                             styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        let crop = CGRect(x: 20, y: 20, width: 740, height: 360)
        canvas.selection = crop
        canvas.commit(ScreenshotAnnotation(tool: .blur, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200)], patch: image))
        canvas.selectTool(.select)
        try body(canvas, window, crop, image)
        XCTAssertFalse(window.isVisible)
    }

    private func drag(_ canvas: ScreenshotCanvas, window: NSWindow, from start: CGPoint, to end: CGPoint) throws {
        func event(_ type: NSEvent.EventType, point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, point: start))
        if start != end { canvas.mouseDragged(with: try event(.leftMouseDragged, point: end)) }
        canvas.mouseUp(with: try event(.leftMouseUp, point: end))
    }
}
