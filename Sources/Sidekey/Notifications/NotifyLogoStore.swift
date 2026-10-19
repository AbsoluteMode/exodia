import AppKit

/// Resolved glyph for a notification icon.
enum LogoGlyph: Equatable {
    case brandImage(name: String) // bundled brand asset OR user custom file
    case symbol(String)           // SF Symbol name
    case initial(Character)       // fallback monogram
}

/// Resolves a payload `logo` name to a renderable glyph. Local-only
/// (on-premise): bundled brand set + user custom files, no network/URL.
///
/// Resolution order for an explicit name: image (custom → bundled) →
/// SF Symbol → initial. For `nil`: the source's own brand asset → its
/// SF Symbol → initial of the source name.
@MainActor
enum NotifyLogoStore {
    static func resolve(
        logo: String?,
        source: String,
        imageExists: (String) -> Bool
    ) -> LogoGlyph {
        if let logo, !logo.isEmpty {
            if imageExists(logo) { return .brandImage(name: logo) }
            if isSymbol(logo) { return .symbol(logo) }
            return .initial(Character(String(logo.uppercased().prefix(1))))
        }
        return .initial(source.uppercased().first ?? "N")
    }

    /// Convenience overload that uses the real bundle + custom-directory lookup.
    static func resolve(logo: String?, source: String) -> LogoGlyph {
        resolve(logo: logo, source: source, imageExists: NotifyLogoStore.imageExists)
    }

    private static func isSymbol(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    static var customLogosDirectory: URL? { NotifyPaths.logos }

    /// True if a bundled brand asset or a user custom file exists for `name`.
    static func imageExists(_ name: String) -> Bool {
        image(named: name) != nil
    }


    /// Loads a brand/custom image as a template image, or nil.
    static func image(named name: String) -> NSImage? {
        // `name` may originate from an external payload (customLogo). Reject
        // anything that could escape the lookup directory before it touches a
        // path: no separators, no leading dot (no `..` traversal, no hidden).
        guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
        var found: NSImage?
        // 1. User custom file (png/pdf) in the custom logos dir.
        if let dir = customLogosDirectory {
            for ext in ["png", "pdf", "jpg", "jpeg"] {
                let url = dir.appendingPathComponent("\(name).\(ext)")
                if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                   values.isSymbolicLink != true, (values.fileSize ?? 0) <= 2_097_152,
                   let img = NSImage(contentsOf: url) {
                    found = img
                    break
                }
            }
        }
        // 2. Bundled brand asset (pdf), incl. UsefulLinkIcons subdir.
        if found == nil {
            let url = Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "UsefulLinkIcons")
                ?? Bundle.main.url(forResource: name, withExtension: "pdf")
            if let url { found = NSImage(contentsOf: url) }
        }
        found?.isTemplate = true
        return found
    }
}
