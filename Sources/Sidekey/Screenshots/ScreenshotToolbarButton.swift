import AppKit

/// Native button tracking/focus/pressed states, with an explicit whole-button hover.
@MainActor
final class ScreenshotToolbarButton: NSButton {
    var isPrimaryAction = false
    private var hoverTracking: NSTrackingArea?
    private var hovered = false
    override var acceptsFirstResponder: Bool { isEnabled }

    override var isEnabled: Bool {
        didSet {
            if !title.isEmpty {
                attributedTitle = NSAttributedString(string: title, attributes: [
                    .foregroundColor: isEnabled ? NSColor.labelColor : .disabledControlTextColor,
                    .font: font ?? NSFont.systemFont(ofSize: 13)
                ])
            }
            needsDisplay = true
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        var primaryForeground = NSColor.labelColor
        if isPrimaryAction {
            var background = isEnabled ? NSColor.controlAccentColor : .quaternaryLabelColor
            if isEnabled && (hovered || isHighlighted) {
                background = background.blended(withFraction: isHighlighted ? 0.16 : 0.08, of: .labelColor) ?? background
            }
            background.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).fill()
            if let rgb = background.usingColorSpace(.sRGB) {
                let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
                    $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
                }
                let luminance = components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
                primaryForeground = 1.05 / (luminance + 0.05) >= (luminance + 0.05) / 0.05 ? .white : .black
            }
        } else if isBordered { super.draw(dirtyRect) }
        if !isPrimaryAction && isEnabled && (hovered || isHighlighted) {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        guard isPrimaryAction || !isBordered, let cell = cell as? NSButtonCell else { return }
        // Inline cells dim unselected content even when enabled. Draw semantic
        // foregrounds at full opacity so the expanded toolbar stays readable.
        let foreground = isEnabled ? (isPrimaryAction ? primaryForeground : NSColor.labelColor) : .disabledControlTextColor
        if let image {
            let symbol = image.withSymbolConfiguration(.init(paletteColors: [foreground])) ?? image
            let available = imagePosition == .imageOnly ? bounds.insetBy(dx: 6, dy: 6) : cell.imageRect(forBounds: bounds)
            let scale = min(available.width / symbol.size.width, available.height / symbol.size.height)
            let rect = CGRect(x: available.midX - symbol.size.width * scale / 2,
                              y: available.midY - symbol.size.height * scale / 2,
                              width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: rect, from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true, hints: nil)
        }
        if !title.isEmpty {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (title as NSString).draw(in: cell.titleRect(forBounds: bounds), withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: foreground,
                .paragraphStyle: paragraph
            ])
        }
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

