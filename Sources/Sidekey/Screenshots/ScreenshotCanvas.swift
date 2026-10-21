import AppKit
import Carbon.HIToolbox

enum ScreenshotCommand: Hashable { case cancel, copy, download, share }

@MainActor
final class ScreenshotCanvas: NSView {
    let source: CGImage
    let documentSize: CGSize
    var selection: CGRect = .zero
    var annotations: [ScreenshotAnnotation] = []
    var tool: ScreenshotTool = .select
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    var labelText = ""
    var blurMode = ScreenshotBlurMode.textAndNumbers
    var busy = false { didSet { needsDisplay = true; onChange?() } }
    var busyMessage = "Processing on this Mac…"
    var message = ""
    var onChange: (() -> Void)?
    var onSelection: (() -> Void)?
    var onBlur: ((CGRect, ScreenshotBlurMode) -> Void)?
    var onCommand: ((ScreenshotCommand) -> Void)?
    let arrowBindings: @MainActor () -> ScreenshotArrowBindings

    private struct Snapshot { let selection: CGRect; let annotations: [ScreenshotAnnotation] }
    private var undoStates: [Snapshot] = [], redoStates: [Snapshot] = []
    private var start: CGPoint = .zero
    private var beforeDrag: Snapshot?
    private var drawing: ScreenshotAnnotation?
    private var movingAnnotation: UUID?
    private var selectedAnnotation: UUID?
    private var movingSelection = false
    private var creatingSelection = false
    private var resizeCorner: CGPoint?
    private var tracking: NSTrackingArea?
    var canUndo: Bool { !busy && !undoStates.isEmpty }
    var canRedo: Bool { !busy && !redoStates.isEmpty }

    init(image: CGImage, size: CGSize, arrowBindings: (@MainActor () -> ScreenshotArrowBindings)? = nil) {
        source = image; documentSize = size
        self.arrowBindings = arrowBindings ?? { HotkeyPreferences.shared.screenshotArrowBindings }
        super.init(frame: CGRect(origin: .zero, size: size))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screenshot selection and annotations")
        setAccessibilityHelp("Drag to select an area. Enter copies that area and closes the editor. Tools and export actions are in the floating toolbar.")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .select && !selection.isEmpty ? .arrow : .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(source, in: bounds)
        context.saveGState()
        if !selection.isEmpty { context.clip(to: selection) }
        for annotation in annotations { ScreenshotRenderer.draw(annotation, in: context, bounds: bounds) }
        if let drawing, drawing.tool != .blur { ScreenshotRenderer.draw(drawing, in: context, bounds: bounds) }
        context.restoreGState()
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill(); shade.fill()
        if !selection.isEmpty {
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5)).stroke()
            if tool == .select {
                for corner in corners {
                    let handle = CGRect(x: corner.x - 3, y: corner.y - 3, width: 6, height: 6)
                    NSColor.white.setFill(); NSBezierPath(rect: handle).fill()
                    NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: handle).stroke()
                }
            }
            if let drawing, drawing.tool == .blur {
                let path = NSBezierPath(rect: drawing.rect)
                path.setLineDash([4, 3], count: 2, phase: 0); path.stroke()
            }
        }
        let text = busy ? busyMessage : message
        (text as NSString).draw(at: CGPoint(x: 20, y: bounds.height - 38), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65)
        ])
    }

    private var corners: [CGPoint] {
        [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
         CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)]
    }
    private func bounded(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }
    private func snapshot() -> Snapshot { Snapshot(selection: selection, annotations: annotations) }
    private func checkpoint(_ snapshot: Snapshot) {
        undoStates.append(snapshot); if undoStates.count > 40 { undoStates.removeFirst() }; redoStates.removeAll()
    }
    func commit(_ annotation: ScreenshotAnnotation) {
        checkpoint(snapshot()); annotations.append(annotation); selectedAnnotation = annotation.id
        needsDisplay = true; onChange?()
    }
    func undo() {
        guard !busy, let state = undoStates.popLast() else { return }
        redoStates.append(snapshot()); restore(state)
    }
    func redo() {
        guard !busy, let state = redoStates.popLast() else { return }
        undoStates.append(snapshot()); restore(state)
    }
    private func restore(_ state: Snapshot) {
        selection = state.selection; annotations = state.annotations; selectedAnnotation = nil
        if selection.isEmpty { tool = .select }
        needsDisplay = true; onSelection?(); onChange?()
    }
    func selectTool(_ value: ScreenshotTool) {
        guard !busy else { return }
        tool = value; selectedAnnotation = nil
        message = ""
        window?.invalidateCursorRects(for: self); needsDisplay = true; onChange?()
    }

    override func mouseDown(with event: NSEvent) {
        guard !busy else { return }
        if selection.isEmpty { tool = .select }
        window?.makeFirstResponder(self)
        start = bounded(convert(event.locationInWindow, from: nil), to: bounds)
        beforeDrag = snapshot(); movingSelection = false; creatingSelection = false; movingAnnotation = nil; resizeCorner = nil
        if selection.isEmpty || tool == .select {
            if let corner = corners.first(where: { hypot($0.x - start.x, $0.y - start.y) <= 10 }), !selection.isEmpty {
                resizeCorner = CGPoint(x: corner.x == selection.minX ? selection.maxX : selection.minX,
                                       y: corner.y == selection.minY ? selection.maxY : selection.minY)
            } else if let annotation = annotations.last(where: { hit($0, point: start) }), selection.contains(start) {
                selectedAnnotation = annotation.id
                if annotation.tool != .blur { movingAnnotation = annotation.id }
                else { message = "Blur selected · Delete to remove, or ⌘Z to undo" }
            } else if selection.contains(start) { movingSelection = true; selectedAnnotation = nil }
            else { selection = CGRect(origin: start, size: .zero); creatingSelection = true; selectedAnnotation = nil }
        } else if selection.contains(start) {
            if tool == .text {
                let text = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { message = "Enter your label in the toolbar first"; needsDisplay = true; return }
                commit(ScreenshotAnnotation(tool: .text, points: [start], color: color, width: lineWidth, text: text)); beforeDrag = nil
            } else if tool == .counter {
                let number = annotations.filter { $0.tool == .counter }.count + 1
                commit(ScreenshotAnnotation(tool: .counter, points: [start], color: color, text: String(number))); beforeDrag = nil
            } else {
                drawing = ScreenshotAnnotation(tool: tool, points: [start, start], color: color, width: lineWidth)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !busy, beforeDrag != nil else { return }
        let oldSelection = selection
        let oldDrawing = drawing?.rect
        let point = bounded(convert(event.locationInWindow, from: nil), to: bounds)
        if var annotation = drawing {
            let inside = bounded(point, to: selection)
            if annotation.tool == .pen { annotation.points.append(inside) }
            else { annotation.points = [start, inside] }
            drawing = annotation
        } else if let id = movingAnnotation, let original = beforeDrag?.annotations.first(where: { $0.id == id }),
                  let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index].points = original.points.map { CGPoint(x: $0.x + point.x - start.x, y: $0.y + point.y - start.y) }
        } else if let fixed = resizeCorner { selection = ScreenshotGeometry.rect(from: fixed, to: point) }
        else if movingSelection, let original = beforeDrag?.selection {
            let origin = CGPoint(x: min(max(0, original.minX + point.x - start.x), bounds.width - original.width),
                                 y: min(max(0, original.minY + point.y - start.y), bounds.height - original.height))
            selection = CGRect(origin: origin, size: original.size)
        } else if creatingSelection {
            // An immovable Blur is selection-only. Only an explicit crop gesture may replace the crop.
            selection = ScreenshotGeometry.rect(from: start, to: point)
        }
        if let drawing, let oldDrawing, ![.text, .counter].contains(drawing.tool) {
            let padding = max(20, drawing.width * 5)
            setNeedsDisplay(oldDrawing.union(drawing.rect).insetBy(dx: -padding, dy: -padding))
        } else if oldSelection != selection {
            setNeedsDisplay(oldSelection.union(selection).insetBy(dx: -12, dy: -12))
        } else { needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        guard !busy, let before = beforeDrag else { return }
        mouseDragged(with: event)
        beforeDrag = nil
        if let annotation = drawing {
            drawing = nil
            if annotation.rect.width >= 2 || annotation.rect.height >= 2 {
                if annotation.tool == .blur { onBlur?(annotation.rect, blurMode) }
                else { commit(annotation) }
            }
        } else if movingAnnotation != nil || before.selection != selection { checkpoint(before) }
        if selection.width < 2 || selection.height < 2 { selection = .zero }
        movingAnnotation = nil; movingSelection = false; creatingSelection = false; resizeCorner = nil
        needsDisplay = true; onSelection?(); onChange?()
    }

    private func hit(_ annotation: ScreenshotAnnotation, point: CGPoint) -> Bool {
        if annotation.tool == .text, let anchor = annotation.points.first {
            let size = (annotation.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: max(14, annotation.width * 6), weight: .medium)])
            return CGRect(origin: anchor, size: size).insetBy(dx: -6, dy: -6).contains(point)
        }
        return annotation.rect.insetBy(dx: -10, dy: -10).contains(point)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if [36, 76].contains(event.keyCode), !(window?.firstResponder is NSTextView) {
            keyDown(with: event); return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !(window?.firstResponder is NSTextView), modifiers == .command || modifiers == [.command, .shift] else { return super.performKeyEquivalent(with: event) }
        // The physical Z key also produces я in Russian. Command dispatch can
        // reach a nonactivating panel without a main-menu key-equivalent pass.
        // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
        if event.keyCode == UInt16(kVK_ANSI_Z) {
            modifiers.contains(.shift) ? redo() : undo(); return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": onCommand?(.copy); return true
        case "s": if !busy { onCommand?(.download) }; return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) {
        if drawing != nil { drawing = nil; beforeDrag = nil; needsDisplay = true }
        else { onCommand?(.cancel) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            (window as? ScreenshotCapturePanel)?.onAdvanceFocus?(event.modifierFlags.contains(.shift))
            return
        }
        if event.keyCode == 53 { cancelOperation(nil); return }
        if [36, 76].contains(event.keyCode) {
            guard !selection.isEmpty else { return }
            onCommand?(.copy)
            return
        }
        if let arrow = ScreenshotArrow(keyCode: event.keyCode),
           event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
            let action = arrowBindings()[arrow]
            if action != .moveCrop {
                // Holding an export key must not execute the same command repeatedly.
                if !event.isARepeat { perform(action) }
                return
            }
        }
        guard !busy else { return }
        if [51, 117].contains(event.keyCode), let id = selectedAnnotation {
            checkpoint(snapshot()); annotations.removeAll { $0.id == id }; selectedAnnotation = nil
            needsDisplay = true; onChange?(); return
        }
        if [123, 124, 125, 126].contains(event.keyCode), !selection.isEmpty {
            checkpoint(snapshot())
            let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -amount : event.keyCode == 124 ? amount : 0
            let dy: CGFloat = event.keyCode == 125 ? -amount : event.keyCode == 126 ? amount : 0
            if event.modifierFlags.contains(.option) {
                selection.size.width = min(bounds.maxX - selection.minX, max(2, selection.width + dx))
                selection.size.height = min(bounds.maxY - selection.minY, max(2, selection.height + dy))
            } else {
                selection.origin.x = min(max(0, selection.minX + dx), bounds.width - selection.width)
                selection.origin.y = min(max(0, selection.minY + dy), bounds.height - selection.height)
            }
            needsDisplay = true; onSelection?(); return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), let entry = ScreenshotEditorKeys.tools.first(where: { $0.key == key }) { selectTool(entry.tool) }
        // The window forwards editor keys here. Bubbling an unknown key back
        // to that window re-enters this method until the stack overflows.
        // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
    }

    private func perform(_ action: ScreenshotEditorAction) {
        if action == .cancel { cancelOperation(nil); return }
        guard !busy else { return }
        guard beforeDrag == nil else { return }
        if let tool = action.tool { selectTool(tool); return }
        switch action {
        case .undo: undo()
        case .redo: redo()
        case .copy: if !selection.isEmpty { onCommand?(.copy) }
        case .download: if !selection.isEmpty { onCommand?(.download) }
        case .share: if !selection.isEmpty { onCommand?(.share) }
        case .cancel: cancelOperation(nil)
        case .deleteAnnotation:
            guard let id = selectedAnnotation else { return }
            checkpoint(snapshot()); annotations.removeAll { $0.id == id }; selectedAnnotation = nil
            needsDisplay = true; onChange?()
        default: break
        }
    }
}
