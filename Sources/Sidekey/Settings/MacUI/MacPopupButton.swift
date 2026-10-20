import AppKit

/// AppKit counterpart of MacMenu, preserving native popup tracking, target/action
/// and accessibility in the screenshot toolbar.
@MainActor
final class MacPopupButton: NSPopUpButton {
    init() {
        super.init(frame: .zero, pullsDown: false)
        cell = MacPopupButtonCell(textCell: "", pullsDown: false)
        font = .systemFont(ofSize: MacPopupMetrics.fontSize, weight: .medium)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        cell?.cellSize ?? NSSize(width: 90, height: MacPopupMetrics.height)
    }
}

private final class MacPopupButtonCell: NSPopUpButtonCell {
    override var cellSize: NSSize {
        let font = font ?? .systemFont(ofSize: MacPopupMetrics.fontSize, weight: .medium)
        let width = (menu?.items.map(\.title) ?? [title]).map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return NSSize(width: ceil(width) + MacPopupMetrics.horizontalPadding * 2
                      + MacPopupMetrics.spacing + MacPopupMetrics.arrowWidth,
                      height: MacPopupMetrics.height)
    }

    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        let shape = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: MacPopupMetrics.radius, yRadius: MacPopupMetrics.radius)
        let background = NSColor.controlBackgroundColor
        (isHighlighted ? background.blended(withFraction: 0.1, of: .labelColor) ?? background : background).setFill()
        shape.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        let foreground = isEnabled ? NSColor.labelColor : .disabledControlTextColor
        let font = font ?? .systemFont(ofSize: MacPopupMetrics.fontSize, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let height = ceil(font.ascender - font.descender)
        let textRect = NSRect(x: frame.minX + MacPopupMetrics.horizontalPadding,
                              y: frame.midY - height / 2,
                              width: max(0, frame.width - MacPopupMetrics.horizontalPadding * 2
                                         - MacPopupMetrics.spacing - MacPopupMetrics.arrowWidth), height: height)
        (title as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: foreground,
                                                               .paragraphStyle: paragraph])
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
        if let arrow = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let rect = NSRect(x: frame.maxX - MacPopupMetrics.horizontalPadding - MacPopupMetrics.arrowWidth,
                              y: frame.midY - arrow.size.height / 2,
                              width: MacPopupMetrics.arrowWidth, height: arrow.size.height)
            arrow.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 0.7 : 0.3,
                       respectFlipped: true, hints: nil)
        }
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSBezierPath(roundedRect: cellFrame, xRadius: MacPopupMetrics.radius, yRadius: MacPopupMetrics.radius).fill()
    }
}
