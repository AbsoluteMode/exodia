import AppKit

@MainActor
private final class ScreenshotColorWell: NSColorWell {
    private var previousLevel: NSWindow.Level?
    override func activate(_ exclusive: Bool) {
        if previousLevel == nil { previousLevel = NSColorPanel.shared.level }
        NSColorPanel.shared.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        super.activate(exclusive)
    }
    override func deactivate() {
        super.deactivate()
        if let previousLevel { NSColorPanel.shared.level = previousLevel }
        previousLevel = nil
    }
}

@MainActor
final class ScreenshotToolbar: NSView {
    weak var canvas: ScreenshotCanvas?
    var onCommand: ((ScreenshotCommand) -> Void)?
    var onLayout: (() -> Void)?
    private let stack = NSStackView()
    private let settings = NSStackView()
    private let mode = MacPopupButton()
    private let shape = MacPopupButton()
    private let width = MacPopupButton()
    private let color = ScreenshotColorWell()
    private let text = NSTextField()
    private var tools: [ScreenshotTool: NSButton] = [:]
    private var undoButton: NSButton!
    private var exportButtons: [NSButton] = []
    private var currentTool = ScreenshotTool.select
    private var layoutTool: ScreenshotTool?
    private let defaults: UserDefaults

    init(canvas: ScreenshotCanvas, defaults: UserDefaults = .standard) {
        self.canvas = canvas; self.defaults = defaults
        super.init(frame: .zero)
        let material = NSVisualEffectView()
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 13
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)
        stack.orientation = .horizontal; stack.spacing = 6; stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 7, bottom: 6, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor), material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor), material.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let row = NSStackView(); row.spacing = 3
        for (tool, symbol, label) in [(ScreenshotTool.arrow, "arrow.up.right", "Arrow · A"),
                                       (.rectangle, "rectangle", "Shape · R / O"), (.pen, "pencil", "Pen · P"),
                                       (.text, "textformat", "Text · T"), (.blur, "text.viewfinder", "Blur · B")] {
            let button = makeButton(symbol: symbol, title: tool == .blur ? "Blur" : "", help: label, action: #selector(chooseTool(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            button.setButtonType(.toggle); row.addArrangedSubview(button); tools[tool] = button
        }
        row.addArrangedSubview(makeButton(symbol: "ellipsis", help: "More tools", action: #selector(showMore(_:))))
        stack.addArrangedSubview(row)
        settings.spacing = 6; settings.alignment = .centerY
        stack.addArrangedSubview(settings)
        let actions = NSStackView(); actions.spacing = 4; actions.alignment = .centerY
        actions.addArrangedSubview(separator())
        undoButton = makeButton(symbol: "arrow.uturn.backward", help: "Undo · ⌘Z", action: #selector(undo(_:)))
        actions.addArrangedSubview(undoButton)
        actions.addArrangedSubview(separator())
        let download = makeButton(symbol: "arrow.down.to.line", title: "Download", help: "Download to Downloads · ⌘S", action: #selector(download(_:)))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyImage(_:)))
        copy.bezelStyle = .rounded; copy.bezelColor = .controlAccentColor
        copy.setAccessibilityLabel("Copy screenshot"); copy.toolTip = "Copy screenshot and finish · Return / ⌘C"
        actions.addArrangedSubview(download); actions.addArrangedSubview(copy); exportButtons = [download, copy]
        stack.addArrangedSubview(actions)
        color.target = self; color.action = #selector(updateSettings(_:))
        color.setAccessibilityLabel("Annotation color")
        color.widthAnchor.constraint(equalToConstant: 32).isActive = true
        color.heightAnchor.constraint(equalToConstant: 24).isActive = true
        settings.addArrangedSubview(color)
        width.addItems(withTitles: ["2 pt", "3 pt", "5 pt", "8 pt"])
        width.target = self; width.action = #selector(updateSettings(_:)); width.setAccessibilityLabel("Line width")
        settings.addArrangedSubview(width)
        shape.addItems(withTitles: ["Rectangle", "Oval"])
        shape.target = self; shape.action = #selector(updateSettings(_:)); shape.setAccessibilityLabel("Shape")
        settings.addArrangedSubview(shape)
        mode.addItems(withTitles: ScreenshotBlurMode.allCases.map(\.rawValue))
        mode.target = self; mode.action = #selector(updateSettings(_:)); mode.setAccessibilityLabel("What to blur")
        settings.addArrangedSubview(mode)
        text.placeholderString = "Label · click to place"; text.target = self; text.action = #selector(finishText(_:))
        text.setAccessibilityLabel("Annotation text"); text.widthAnchor.constraint(equalToConstant: 160).isActive = true
        text.toolTip = "Type a label, then click the screenshot to place it. Return copies placed annotations and closes; unplaced text is discarded."
        text.setAccessibilityHelp(text.toolTip)
        NotificationCenter.default.addObserver(self, selector: #selector(updateSettings(_:)), name: NSControl.textDidChangeNotification, object: text)
        settings.addArrangedSubview(text)
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    func closeAuxiliaryWindows() {
        if color.isActive { color.deactivate(); NSColorPanel.shared.orderOut(nil) }
    }

    func refresh() {
        guard let canvas else { return }
        let tool = canvas.tool
        if tool != currentTool {
            currentTool = tool
            let saved = defaults.array(forKey: "sidekey.screenshot.color.\(tool.rawValue)") as? [Double]
            color.color = saved?.count == 4 ? NSColor(srgbRed: saved![0], green: saved![1], blue: saved![2], alpha: saved![3]) : tool == .marker ? .systemYellow : .systemRed
            width.selectItem(at: min(3, max(0, defaults.object(forKey: "sidekey.screenshot.width.\(tool.rawValue)") as? Int ?? 1)))
            canvas.color = color.color; canvas.lineWidth = [2, 3, 5, 8][width.indexOfSelectedItem]
        }
        for (kind, button) in tools {
            button.state = tool == kind || (kind == .rectangle && tool == .ellipse) ? .on : .off
            button.isEnabled = !canvas.busy
            button.contentTintColor = .labelColor
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.backgroundColor = button.state == .on ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        }
        undoButton.isEnabled = canvas.canUndo
        for button in exportButtons { button.isEnabled = !canvas.busy && !canvas.selection.isEmpty }
        settings.isHidden = tool == .select
        color.isHidden = [.select, .blur, .spotlight].contains(tool)
        width.isHidden = ![.arrow, .rectangle, .ellipse, .pen, .text].contains(tool)
        shape.isHidden = tool != .rectangle && tool != .ellipse
        shape.selectItem(at: tool == .ellipse ? 1 : 0)
        mode.isHidden = tool != .blur
        mode.selectItem(withTitle: canvas.blurMode.rawValue)
        text.isHidden = tool != .text
        for control in [color as NSControl, width, shape, mode, text] { control.isEnabled = !canvas.busy }
        if layoutTool != tool {
            layoutTool = tool
            layoutSubtreeIfNeeded(); onLayout?()
        }
    }

    private func makeButton(symbol: String, title: String = "", help: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.bezelStyle = .inline; button.isBordered = false
        button.toolTip = help; button.setAccessibilityLabel(help.components(separatedBy: " · ")[0])
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: title.isEmpty ? 30 : 60).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }
    private func separator() -> NSView {
        let view = NSBox(); view.boxType = .separator
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return view
    }
    @objc private func chooseTool(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let tool = ScreenshotTool(rawValue: value) else { return }
        canvas?.selectTool(tool); canvas?.window?.makeKey(); canvas?.window?.makeFirstResponder(canvas)
    }
    @objc private func updateSettings(_ sender: Any?) {
        guard let canvas else { return }
        canvas.color = color.color; canvas.lineWidth = [2, 3, 5, 8][max(0, width.indexOfSelectedItem)]
        canvas.labelText = text.stringValue
        canvas.blurMode = ScreenshotBlurMode.allCases[max(0, mode.indexOfSelectedItem)]
        if sender as? NSPopUpButton === shape {
            canvas.selectTool(shape.indexOfSelectedItem == 0 ? .rectangle : .ellipse)
        }
        if let rgb = color.color.usingColorSpace(.sRGB) {
            defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent], forKey: "sidekey.screenshot.color.\(canvas.tool.rawValue)")
        }
        defaults.set(width.indexOfSelectedItem, forKey: "sidekey.screenshot.width.\(canvas.tool.rawValue)")
    }
    @objc private func undo(_ sender: Any?) { canvas?.undo() }
    @objc private func finishText(_ sender: Any?) {
        updateSettings(sender)
        onCommand?(.copy)
    }
    @objc private func download(_ sender: Any?) { onCommand?(.download) }
    @objc private func copyImage(_ sender: Any?) { onCommand?(.copy) }
    @objc private func menuTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = ScreenshotTool(rawValue: raw) else { return }
        canvas?.selectTool(tool); canvas?.window?.makeKey(); canvas?.window?.makeFirstResponder(canvas)
    }
    @objc private func menuCommand(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "text": onCommand?(.copyText)
        case "pin": onCommand?(.pin)
        case "share": onCommand?(.share)
        case "resize": onCommand?(.resize)
        case "redo": canvas?.redo()
        default: onCommand?(.cancel)
        }
    }
    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu(); menu.autoenablesItems = false
        for (title, tool) in [("Select & crop · V", ScreenshotTool.select), ("Highlighter · M", .marker),
                              ("Numbered steps · N", .counter), ("Spotlight", .spotlight)] {
            let item = NSMenuItem(title: title, action: #selector(menuTool(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = tool.rawValue; item.isEnabled = canvas?.busy == false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, command) in [("Copy text", "text"), ("Pin above windows", "pin"), ("Output size…", "resize"),
                                  ("Share…", "share"), ("Redo", "redo"), ("Cancel capture", "cancel")] {
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = command
            item.isEnabled = command == "cancel" || (canvas?.busy == false && (command != "redo" || canvas?.canRedo == true))
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
}
