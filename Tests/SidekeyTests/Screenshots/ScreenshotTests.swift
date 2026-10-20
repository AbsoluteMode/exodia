import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class ScreenshotTests: XCTestCase {
    private func fixture(width: Int = 800, height: Int = 400, text: Bool = true) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if text {
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 44, weight: .medium), .foregroundColor: NSColor.black]
            ("Invoice" as NSString).draw(at: CGPoint(x: 55, y: 290), withAttributes: attributes)
            ("401" as NSString).draw(at: CGPoint(x: 580, y: 190), withAttributes: attributes)
            ("123456" as NSString).draw(at: CGPoint(x: 55, y: 75), withAttributes: attributes)
            NSGraphicsContext.current = previous
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                                 bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    func testRetinaCropClipsToImageAndFlipsOnlyTheCropOrigin() {
        let size = CGSize(width: 1000, height: 500), pixels = CGSize(width: 2000, height: 1000)
        XCTAssertEqual(ScreenshotGeometry.pixelRect(CGRect(x: 100, y: 300, width: 200, height: 100), size: size, pixels: pixels),
                       CGRect(x: 200, y: 200, width: 400, height: 200))
        XCTAssertEqual(ScreenshotGeometry.pixelRect(CGRect(x: -10, y: -10, width: 30, height: 30), size: size, pixels: pixels),
                       CGRect(x: 0, y: 960, width: 40, height: 40))
        XCTAssertTrue(ScreenshotGeometry.pixelRect(CGRect(x: 2000, y: 1000, width: 10, height: 10), size: size, pixels: pixels).isNull)
    }

    func testToolbarFitsNegativeOriginDisplayAndMovesAboveBottomSelection() {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let selection = CGRect(x: -1435, y: -195, width: 50, height: 40)
        let frame = ScreenshotGeometry.toolbarFrame(selection: selection, screen: screen, size: CGSize(width: 450, height: 85))
        XCTAssertTrue(screen.contains(frame)); XCTAssertGreaterThan(frame.minY, selection.maxY)
        let narrow = ScreenshotGeometry.toolbarFrame(selection: .zero, screen: CGRect(x: 0, y: 0, width: 400, height: 300), size: CGSize(width: 450, height: 85))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 400, height: 300).contains(narrow))
    }

    func testVisionFindsStandaloneNumbersAndWordsWithoutLanguageCorrection() throws {
        let result = try ScreenshotTextDetector.analyze(fixture())
        XCTAssertTrue(result.text.contains("401"), "Standalone numbers must be recognized")
        XCTAssertTrue(result.text.contains("123456"))
        XCTAssertTrue(result.text.lowercased().contains("invoice"))
        XCTAssertTrue(result.boxes.contains { $0.contains(CGPoint(x: 0.775, y: 0.54)) }, "Bounding boxes use bottom-left coordinates")
    }

    func testBlankSelectionDoesNotInventTextRegions() throws {
        let result = try ScreenshotTextDetector.analyze(fixture(text: false))
        XCTAssertTrue(result.text.isEmpty); XCTAssertTrue(result.boxes.isEmpty)
    }

    func testTextBlurChangesOnlyDetectedRegionsAndLeavesBackgroundUntouched() throws {
        let source = try fixture(), result = try ScreenshotTextDetector.analyze(source)
        let blurred = try ScreenshotRenderer.blurred(source, boxes: result.boxes)
        let before = try pixels(source), after = try pixels(blurred)
        XCTAssertNotEqual(before, after)
        // Icon / separator stand-ins outside all recognized text remain pixel-identical.
        for y in [10, 350, 390] {
            for x in [10, 400, 790] {
                let offset = (y * source.width + x) * 4
                XCTAssertEqual(Array(before[offset..<offset+4]), Array(after[offset..<offset+4]))
            }
        }
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: blurred).representation(using: .png, properties: [:]))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png)?.cgImage)
        XCTAssertEqual(try pixels(decoded), after, "Export must contain the modified pixels")
    }

    func testRenderedPatchAndCropPreserveOriginalOrientationAtRetinaScale() throws {
        let source = try fixture()
        let size = CGSize(width: 400, height: 200), crop = CGRect(x: 270, y: 90, width: 90, height: 50)
        let patch = try ScreenshotRenderer.image(source: source, size: size, annotations: [], crop: crop)
        let text = try ScreenshotTextDetector.analyze(patch).text
        XCTAssertTrue(text.contains("401"))
        let blurred = try ScreenshotRenderer.blurred(patch, boxes: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        let annotation = ScreenshotAnnotation(tool: .blur, points: [crop.origin, CGPoint(x: crop.maxX, y: crop.maxY)], patch: blurred)
        let rendered = try ScreenshotRenderer.image(source: source, size: size, annotations: [annotation], crop: crop)
        XCTAssertEqual(rendered.width, patch.width); XCTAssertEqual(rendered.height, patch.height)
        XCTAssertNotEqual(try pixels(rendered), try pixels(patch))
        let outside = CGRect(x: 0, y: 130, width: 200, height: 70)
        let before = try ScreenshotRenderer.image(source: source, size: size, annotations: [], crop: outside)
        let after = try ScreenshotRenderer.image(source: source, size: size, annotations: [annotation], crop: outside)
        XCTAssertEqual(try pixels(before), try pixels(after))
    }

    func testUndoRedoRetainsBlurPixelsAndSelection() throws {
        let source = try fixture(), canvas = ScreenshotCanvas(image: source, size: CGSize(width: 800, height: 400))
        canvas.selection = canvas.bounds
        let blurred = try ScreenshotRenderer.blurred(source, boxes: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        canvas.commit(ScreenshotAnnotation(tool: .blur, points: [.zero, CGPoint(x: 800, y: 400)], patch: blurred))
        XCTAssertTrue(canvas.canUndo); XCTAssertEqual(canvas.annotations.count, 1)
        canvas.undo(); XCTAssertTrue(canvas.annotations.isEmpty); XCTAssertTrue(canvas.canRedo)
        canvas.redo(); XCTAssertEqual(canvas.annotations.count, 1)
        XCTAssertEqual(canvas.selection, canvas.bounds)
        XCTAssertTrue(canvas.annotations[0].patch === blurred)
        canvas.busy = true; canvas.undo(); XCTAssertEqual(canvas.annotations.count, 1)
    }

    func testScreenshotSearchAndActivationAreIndependentOfPinnedLayout() {
        XCTAssertEqual(IslandHoverToolSearch.results(for: "скриншот"), [.screenshot])
        XCTAssertEqual(IslandHoverToolSearch.results(for: "blur text numbers"), [.screenshot])
        XCTAssertEqual(HoverSlotRouter.effect(for: .screenshot), .openScreenshot)
        XCTAssertFalse(HoverSlotRouter.effect(for: .screenshot).requiresExpansion)
        var calls = 0, actions = IslandActions.noOp
        actions.openScreenshot = { calls += 1 }
        HoverSlotRouter.effect(for: .screenshot).invoke(on: actions)
        XCTAssertEqual(calls, 1)
    }

    func testOutputResizeKeepsAspectRatioAndRejectsUnboundedDimensions() throws {
        let source = try fixture()
        let smaller = try ScreenshotRenderer.resized(source, width: 200)
        XCTAssertEqual(smaller.width, 200); XCTAssertEqual(smaller.height, 100)
        XCTAssertThrowsError(try ScreenshotRenderer.resized(source, width: 0))
        XCTAssertThrowsError(try ScreenshotRenderer.resized(source, width: 20_000))
    }

    func testRealCanvasGesturesSelectCropAndRequestTextAndNumberBlur() throws {
        let canvas = ScreenshotCanvas(image: try fixture(), size: CGSize(width: 800, height: 400))
        let window = ScreenshotCapturePanel(contentRect: CGRect(x: -20_000, y: -20_000, width: 800, height: 400),
                                             styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = canvas; window.keyboardCanvas = canvas
        defer { window.contentView = nil; window.close() }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func drag(_ start: CGPoint, _ end: CGPoint) throws {
            canvas.mouseDown(with: try event(.leftMouseDown, start))
            canvas.mouseDragged(with: try event(.leftMouseDragged, end))
            canvas.mouseUp(with: try event(.leftMouseUp, end))
        }
        try drag(CGPoint(x: 10, y: 20), CGPoint(x: 750, y: 380))
        XCTAssertEqual(canvas.selection, CGRect(x: 10, y: 20, width: 740, height: 360))
        var requests: [(CGRect, ScreenshotBlurMode)] = []
        canvas.onBlur = { requests.append(($0, $1)) }
        canvas.selectTool(.blur)
        try drag(CGPoint(x: 540, y: 180), CGPoint(x: 700, y: 250))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].0, CGRect(x: 540, y: 180, width: 160, height: 70))
        XCTAssertEqual(requests[0].1, .textAndNumbers)
        canvas.busy = true
        try drag(CGPoint(x: 540, y: 180), CGPoint(x: 700, y: 250))
        XCTAssertEqual(requests.count, 1)
        canvas.busy = false; canvas.undo()
        XCTAssertTrue(canvas.selection.isEmpty); XCTAssertEqual(canvas.tool, .select)
        try drag(CGPoint(x: 40, y: 50), CGPoint(x: 300, y: 200))
        XCTAssertEqual(canvas.selection, CGRect(x: 40, y: 50, width: 260, height: 150))
        XCTAssertFalse(window.isVisible)
    }

    func testScreenshotKeyboardCommandsAndHelpAgree() throws {
        let canvas = ScreenshotCanvas(image: try fixture(), size: CGSize(width: 800, height: 400))
        var selectionEvents = 0
        canvas.onSelection = { selectionEvents += 1 }
        let fullDisplay = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        canvas.keyDown(with: fullDisplay)
        XCTAssertEqual(canvas.selection, canvas.bounds); XCTAssertEqual(selectionEvents, 1)
        for entry in ScreenshotEditorKeys.tools {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: 0, context: nil, characters: entry.key,
                                                       charactersIgnoringModifiers: entry.key, isARepeat: false, keyCode: 0))
            canvas.keyDown(with: event)
            XCTAssertEqual(canvas.tool, entry.tool)
            XCTAssertTrue(HelpWindowContent.hotkeyRows.contains { $0.title == "Screenshot — \(entry.title)" })
        }
        var copied = false
        canvas.onCommand = { command in if case .copy = command { copied = true } }
        let copy = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        canvas.busy = true; XCTAssertTrue(canvas.performKeyEquivalent(with: copy)); XCTAssertFalse(copied)
        canvas.busy = false; XCTAssertTrue(canvas.performKeyEquivalent(with: copy)); XCTAssertTrue(copied)
    }

    func testOffscreenToolbarShowsDedicatedBlurAndBothModesWithoutOpeningApp() throws {
        _ = NSApplication.shared
        let suite = "ScreenshotTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let canvas = ScreenshotCanvas(image: try fixture(), size: CGSize(width: 800, height: 400))
        canvas.selection = CGRect(x: 100, y: 100, width: 200, height: 100)
        canvas.selectTool(.blur)
        let toolbar = ScreenshotToolbar(canvas: canvas, defaults: defaults)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 500, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = toolbar
        defer { window.contentView = nil; window.close() }
        window.setContentSize(toolbar.fittingSize); toolbar.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(toolbar)
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.title == "Blur" && $0.state == .on })
        let mode = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Text and numbers") })
        XCTAssertEqual(mode.titleOfSelectedItem, "Text and numbers")
        XCTAssertEqual(mode.itemTitles, ["Text and numbers", "Entire area"])
        XCTAssertLessThanOrEqual(toolbar.fittingSize.width, 600)
        XCTAssertLessThanOrEqual(toolbar.fittingSize.height, 100)
        XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_TEST_RENDER_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                toolbar.displayIfNeeded()
                let bitmap = try XCTUnwrap(toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds))
                toolbar.cacheDisplay(in: toolbar.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("screenshot-toolbar-\(name).png"))
            }
        }
    }
}
