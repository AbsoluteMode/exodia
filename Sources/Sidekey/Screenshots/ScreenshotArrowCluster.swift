import AppKit
import Combine

/// Assignment controls live with the screenshot tools. They never execute an
/// export on click: the physical arrows run actions; clicking changes a binding.
@MainActor
final class ScreenshotArrowCluster: NSView {
    static let size = CGSize(width: 96, height: 60)
    private let preferences: HotkeyPreferences
    private var observation: AnyCancellable?
    private(set) var buttons: [ScreenshotArrow: ScreenshotToolbarButton] = [:]
    var isEnabled = true {
        didSet {
            for button in buttons.values {
                button.isEnabled = isEnabled
                button.menu?.items.filter { !$0.isSeparatorItem }.forEach { $0.isEnabled = isEnabled }
            }
        }
    }
    var focusableControls: [NSControl] { [.up, .left, .right, .down].compactMap { buttons[$0] }.filter(\.isEnabled) }

    init(preferences: HotkeyPreferences) {
        self.preferences = preferences
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        setAccessibilityElement(false)
        for direction in ScreenshotArrow.allCases {
            let button = ScreenshotToolbarButton(title: "", target: self, action: #selector(showAssignments(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(direction.rawValue)
            button.assignmentArrow = direction
            button.isBordered = false; button.imagePosition = .imageOnly; button.focusRingType = .exterior
            button.onDropAction = { [weak self] action in
                guard let self, self.isEnabled else { return false }
                self.preferences.screenshotArrowBindings[direction] = action
                return true
            }
            addSubview(button); buttons[direction] = button
        }
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
        observation = preferences.$screenshotArrowBindings.sink { [weak self] in self?.refresh($0) }
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { Self.size }
    override func layout() {
        super.layout()
        buttons[.up]?.frame = CGRect(x: 32, y: 32, width: 32, height: 28)
        buttons[.left]?.frame = CGRect(x: 0, y: 16, width: 32, height: 28)
        buttons[.right]?.frame = CGRect(x: 64, y: 16, width: 32, height: 28)
        buttons[.down]?.frame = CGRect(x: 32, y: 0, width: 32, height: 28)
    }

    private func refresh(_ bindings: ScreenshotArrowBindings) {
        for (direction, button) in buttons {
            let action = bindings[direction]
            button.dragAction = action
            button.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            button.setAccessibilityLabel("\(direction.glyph) \(action.title) — change assignment")
            button.setAccessibilityValue(action.title)
            button.toolTip = "\(direction.glyph): \(action.title). Drag a toolbar tool here to replace this action, drag this assignment to another arrow, or click to choose. Changes save immediately."
            button.setAccessibilityHelp(button.toolTip)
            let menu = NSMenu(title: "\(direction.glyph) arrow")
            menu.autoenablesItems = false
            for candidate in ScreenshotEditorAction.allCases {
                let item = NSMenuItem(title: candidate.title, action: #selector(assign(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = [direction.rawValue, candidate.rawValue]
                item.image = NSImage(systemSymbolName: candidate.symbol, accessibilityDescription: nil)
                item.state = candidate == action ? .on : .off
                item.isEnabled = isEnabled
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let reset = NSMenuItem(title: "Reset this arrow", action: #selector(assign(_:)), keyEquivalent: "")
            reset.target = self; reset.representedObject = [direction.rawValue, ScreenshotArrowBindings.defaults[direction].rawValue]
            reset.isEnabled = isEnabled
            menu.addItem(reset); button.menu = menu; button.needsDisplay = true
        }
    }
    @objc private func showAssignments(_ sender: NSButton) {
        guard isEnabled, let menu = sender.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.midX, y: sender.bounds.minY), in: sender)
    }
    @objc private func assign(_ sender: NSMenuItem) {
        guard isEnabled, let parts = sender.representedObject as? [String], parts.count == 2,
              let direction = ScreenshotArrow(rawValue: parts[0]), let action = ScreenshotEditorAction(rawValue: parts[1]) else { return }
        preferences.screenshotArrowBindings[direction] = action
    }
}
