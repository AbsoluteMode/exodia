import XCTest
import SwiftUI
import AppKit
@testable import Sidekey

@MainActor
final class MacSettingsThemeTests: XCTestCase {
    func test_hexCSS_parses_accent_blue() throws {
        let ns = NSColor(Color(hexCSS: "#007aff")).usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(ns.redComponent), 0.0, accuracy: 0.01)
        XCTAssertEqual(Double(ns.greenComponent), 0.478, accuracy: 0.01)
        XCTAssertEqual(Double(ns.blueComponent), 1.0, accuracy: 0.01)
    }

    func test_hexCSS_parses_shorthand_and_ignores_hash() throws {
        let a = NSColor(Color(hexCSS: "#fff")).usingColorSpace(.sRGB)!
        let b = NSColor(Color(hexCSS: "ffffff")).usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(a.redComponent), 1.0, accuracy: 0.01)
        XCTAssertEqual(Double(b.blueComponent), 1.0, accuracy: 0.01)
    }

    func test_dynamic_palette_resolves_both_appearances_with_readable_text() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for background in [MacSettingsTheme.bgContent, MacSettingsTheme.bgCard, MacSettingsTheme.bgSidebar] {
                let bg = try resolve(NSColor(background), in: appearance)
                for foreground in [MacSettingsTheme.text, MacSettingsTheme.text2, MacSettingsTheme.text3] {
                    let fg = try resolve(NSColor(foreground), in: appearance)
                    XCTAssertGreaterThanOrEqual(contrast(fg, bg), 4.5, "\(name): \(fg) on \(bg)")
                }
            }
            let card = try resolve(NSColor(MacSettingsTheme.bgCard), in: appearance)
            XCTAssertGreaterThanOrEqual(contrast(try resolve(NSColor(MacSettingsTheme.text), in: appearance),
                                                try resolve(NSColor(MacSettingsTheme.selection), in: appearance)), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(try resolve(NSColor(MacSettingsTheme.text), in: appearance),
                                                try resolve(NSColor(MacSettingsTheme.controlBg), in: appearance)), 4.5)
            let border = try resolve(NSColor(MacSettingsTheme.switchBorder), in: appearance)
            XCTAssertGreaterThanOrEqual(contrast(border, card), 3)
            let field = try resolve(NSColor(MacSettingsTheme.fieldBg), in: appearance)
            XCTAssertGreaterThanOrEqual(contrast(border, field), 3)
            let blue = try resolve(NSColor(MacSettingsTheme.accent), in: appearance)
            let tintedAction = try XCTUnwrap(card.blended(withFraction: 0.06, of: blue))
            XCTAssertGreaterThanOrEqual(contrast(blue, tintedAction), 4.5)
            for status in [MacSettingsTheme.green, MacSettingsTheme.red, MacSettingsTheme.orange, MacSettingsTheme.accent] {
                XCTAssertGreaterThanOrEqual(contrast(try resolve(NSColor(status), in: appearance), card), 4.5)
            }
            XCTAssertGreaterThanOrEqual(contrast(try resolve(NSColor(MacSettingsTheme.accentFill), in: appearance),
                                                NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)), 4.5)
        }
        let light = try resolve(MacSettingsTheme.NS.text, in: XCTUnwrap(NSAppearance(named: .aqua)))
        let dark = try resolve(MacSettingsTheme.NS.text, in: XCTUnwrap(NSAppearance(named: .darkAqua)))
        XCTAssertLessThan(light.redComponent, 0.2)
        XCTAssertGreaterThan(dark.redComponent, 0.9)
    }

    private func resolve(_ color: NSColor, in appearance: NSAppearance) throws -> NSColor {
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) }
        return try XCTUnwrap(result)
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            func linear(_ component: CGFloat) -> Double {
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return linear(color.redComponent) * 0.2126 + linear(color.greenComponent) * 0.7152 + linear(color.blueComponent) * 0.0722
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
