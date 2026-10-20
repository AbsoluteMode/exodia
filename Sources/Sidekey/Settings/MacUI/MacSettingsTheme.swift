import SwiftUI
import AppKit

extension Color {
    /// Parse a CSS hex string ("#rgb", "#rrggbb", with or without '#') into a Color.
    init(hexCSS raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v & 0xFF0000) >> 16) / 255.0
        let g = Double((v & 0x00FF00) >> 8) / 255.0
        let b = Double(v & 0x0000FF) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

/// Appearance-aware grouped settings. AppKit and SwiftUI share the same dynamic
/// colors, so an open window follows a system appearance change immediately.
// WHY: docs/DESIGN.md — Settings appearance and switches.
enum MacSettingsTheme {
    static let accent = Color(nsColor: NS.accent)
    /// Filled actions retain white-label contrast in both appearances.
    static let accentFill = Color(hexCSS: "#0064D2")
    static let accentPress = adaptive("accentPress", light: 0x005DC7, dark: 0x409CFF)

    // radii
    static let radiusCard: CGFloat = 14
    static let radiusWin: CGFloat = 18

    // surfaces
    static let bgContent = adaptive("content", light: 0xF2F2F7, dark: 0x1C1C1E)
    static let bgCard = adaptive("card", light: 0xFFFFFF, dark: 0x2C2C2E)
    static let bgSidebar = adaptive("sidebar", light: 0xE8E8ED, dark: 0x242426)
    static let bgTitlebar = adaptive("titlebar", light: 0xF2F2F7, dark: 0x242426)

    // text
    static let text = Color(nsColor: NS.text)
    static let text2 = Color(nsColor: NS.text2)
    static let text3 = adaptive("tertiary", light: 0x65656B, dark: 0xA6A6AD)

    // separators / hover
    static let sep = Color(nsColor: NS.sep)
    static let sepStrong = adaptive("border", light: 0xC5C5CC, dark: 0x545458)
    static let hover = Color(nsColor: NS.hover)
    /// Neutral grey fill for list-row selection (calm, not accent-blue).
    /// SwiftUI mirror of `MacSettingsTheme.NS.selection`.
    static let selection = Color(nsColor: NS.selection)

    // controls
    static let segBg = adaptive("segments", light: 0xE3E3E8, dark: 0x39393D)
    static let segSel = adaptive("selectedSegment", light: 0xFFFFFF, dark: 0x636366)
    static let controlBg = adaptive("control", light: 0xEDEDF2, dark: 0x48484C)
    static let fieldBg = adaptive("field", light: 0xFFFFFF, dark: 0x202022)
    static let switchOff = adaptive("switchOff", light: 0xDADADD, dark: 0x3F3F44)
    static let switchBorder = adaptive("switchBorder", light: 0x79797F, dark: 0x98989F)
    static let switchOn = Color(hexCSS: "#26BF4D")

    // status pills
    static let green = adaptive("success", light: 0x196F3D, dark: 0x64D98B)
    static let red = adaptive("danger", light: 0xBE2535, dark: 0xFF8585)
    static let orange = adaptive("warning", light: 0x895000, dark: 0xFFC16C)

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NS.adaptive(name, light: light, dark: dark))
    }
}

extension MacSettingsTheme {
    /// AppKit (`NSColor`) mirrors of the tokens, for chrome that is not SwiftUI —
    /// the Meetings sidebar `NSTableView` and tab bar.
    enum NS {
        static let accent = adaptive("accent", light: 0x0064D2, dark: 0x409CFF)
        /// Neutral grey fill for Notes list-row selection (calm, not accent-blue).
        static let selection = adaptive("selection", light: 0xD8D8DF, dark: 0x48484C)
        static let text = adaptive("text", light: 0x1C1C1E, dark: 0xF2F2F7)
        static let text2 = adaptive("secondary", light: 0x5C5C64, dark: 0xB5B5BD)
        static let sep = adaptive("separator", light: 0xD6D6DD, dark: 0x454549)
        static let hover = adaptive("hover", light: 0xDDDEE5, dark: 0x36363A)

        fileprivate static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
            NSColor(name: NSColor.Name("Whytap.Settings.\(name)")) { appearance in
                let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                               green: CGFloat((value >> 8) & 255) / 255,
                               blue: CGFloat(value & 255) / 255, alpha: 1)
            }
        }
    }
}
