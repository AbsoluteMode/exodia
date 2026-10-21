import AppKit

enum ScreenshotArrow: String, CaseIterable, Identifiable {
    case up, down, left, right
    var id: Self { self }
    var glyph: String { switch self { case .up: return "↑"; case .down: return "↓"; case .left: return "←"; case .right: return "→" } }
    var keyCode: UInt16 { switch self { case .up: return 126; case .down: return 125; case .left: return 123; case .right: return 124 } }
    init?(keyCode: UInt16) {
        guard let arrow = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = arrow
    }
}

enum ScreenshotEditorAction: String, CaseIterable, Identifiable {
    case pen, blur, arrow, rectangle, ellipse, text, counter
    case undo, redo, copy, copyText, download, share, cancel, deleteAnnotation, moveCrop
    var id: Self { self }
    var title: String {
        switch self {
        case .pen: return "Pen"
        case .blur: return "Blur"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Oval"
        case .text: return "Text"
        case .counter: return "Numbered steps"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .copy: return "Copy & exit"
        case .copyText: return "Copy text"
        case .download: return "Download"
        case .share: return "Share"
        case .cancel: return "Cancel capture"
        case .deleteAnnotation: return "Delete annotation"
        case .moveCrop: return "Move crop"
        }
    }
    var symbol: String {
        switch self {
        case .pen: return "pencil"
        case .blur: return "drop.halffull"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .text: return "textformat"
        case .counter: return "number.circle"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .copy: return "doc.on.doc"
        case .copyText: return "doc.text.viewfinder"
        case .download: return "arrow.down.to.line"
        case .share: return "square.and.arrow.up"
        case .cancel: return "xmark"
        case .deleteAnnotation: return "delete.left"
        case .moveCrop: return "arrow.up.left.and.arrow.down.right"
        }
    }
    var tool: ScreenshotTool? { ScreenshotTool(rawValue: rawValue) }
    var dragPayload: String { "whytap.screenshot.action:\(rawValue)" }
    init?(dragPayload: String) {
        let prefix = "whytap.screenshot.action:"
        guard dragPayload.hasPrefix(prefix) else { return nil }
        self.init(rawValue: String(dragPayload.dropFirst(prefix.count)))
    }
}

struct ScreenshotArrowBindings: Equatable {
    private var actions: [ScreenshotArrow: ScreenshotEditorAction]
    static let defaults = Self(actions: [.up: .blur, .left: .rectangle, .right: .pen, .down: .text])
    private init(actions: [ScreenshotArrow: ScreenshotEditorAction]) { self.actions = actions }
    init(saved: [String: String]?) {
        actions = Self.defaults.actions
        for (key, value) in saved ?? [:] {
            guard let arrow = ScreenshotArrow(rawValue: key), let action = ScreenshotEditorAction(rawValue: value) else { continue }
            actions[arrow] = action
        }
    }
    subscript(_ arrow: ScreenshotArrow) -> ScreenshotEditorAction {
        get { actions[arrow] ?? Self.defaults.actions[arrow]! }
        set { actions[arrow] = newValue }
    }
    var saved: [String: String] { Dictionary(uniqueKeysWithValues: ScreenshotArrow.allCases.map { ($0.rawValue, self[$0].rawValue) }) }
    @discardableResult
    mutating func replace(_ arrow: ScreenshotArrow, with payloads: [String]) -> Bool {
        guard payloads.count == 1, let payload = payloads.first, let action = ScreenshotEditorAction(dragPayload: payload) else { return false }
        self[arrow] = action
        return true
    }
}
