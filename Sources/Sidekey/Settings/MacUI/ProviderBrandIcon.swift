import AppKit
import SwiftUI

/// Tiny monochrome brand mark for dense Settings rows.
@MainActor
struct ProviderBrandIcon: View {
    let assetName: String?
    let systemName: String?
    var size: CGFloat
    var color: Color

    init(assetName: String, size: CGFloat = 18, color: Color = MacSettingsTheme.text2) {
        self.assetName = assetName
        self.systemName = nil
        self.size = size
        self.color = color
    }

    init(systemName: String, size: CGFloat = 18, color: Color = MacSettingsTheme.text2) {
        self.assetName = nil
        self.systemName = systemName
        self.size = size
        self.color = color
    }

    init(brand: TranscriptionProviderBrand, size: CGFloat = 18, color: Color = MacSettingsTheme.text2) {
        self.assetName = brand.assetName
        self.systemName = brand.systemName
        self.size = size
        self.color = color
    }

    var body: some View {
        icon
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        if let assetName, let image = ProviderBrandIconAsset.image(named: assetName, pointSize: size) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
        } else {
            Image(systemName: systemName ?? "circle")
                .font(.system(size: size * 0.72, weight: .semibold))
        }
    }
}

@MainActor
enum ProviderBrandIconAsset {
    /// Brand marks prewarmed at startup so the Dynamic Island breathing ticker
    /// never pays a cold PDF decode on first show (the ticker appears exactly
    /// when the main thread is busy). Covers drop transcription providers plus
    /// the agent CLIs and Google now shown during agent / Google voice turns.
    static let transcriptionProviderAssetNames = [
        "soniox",
        "deepgram",
        "openai",
        "elevenlabs",
        "codex",
        "claude-code",
        "google",
        "openrouter",
    ] + AgentModelBrand.allCases.map(\.assetName)
    static let prewarmedPointSizes: [CGFloat] = [15, 18]

    @discardableResult
    static func prewarmTranscriptionProviderAssets() -> Int {
        prewarm(
            assetNames: transcriptionProviderAssetNames,
            pointSizes: prewarmedPointSizes
        )
    }

    @discardableResult
    static func prewarm(assetNames: [String], pointSizes: [CGFloat]) -> Int {
        assetNames.reduce(0) { total, name in
            total + pointSizes.reduce(0) { count, pointSize in
                image(named: name, pointSize: pointSize) == nil ? count : count + 1
            }
        }
    }

    static func image(named assetName: String) -> NSImage? {
        sourceImage(named: assetName)
    }

    static func image(named assetName: String, pointSize: CGFloat) -> NSImage? {
        let key = RenderedKey(assetName: assetName, pointSize: pointSize)
        if let cached = renderedCache[key] { return cached }
        guard let source = sourceImage(named: assetName) else {
            return nil
        }
        let rendered = renderTemplateImage(source, pointSize: key.pointSize)
        renderedCache[key] = rendered
        return rendered
    }

    private static func sourceImage(named assetName: String) -> NSImage? {
        if let cached = sourceCache[assetName] { return cached }
        guard let url = url(named: assetName) else {
            return nil
        }
        let image = NSImage(contentsOf: url)
        image?.isTemplate = true
        if let image {
            sourceCache[assetName] = image
        }
        return image
    }

    private static func renderTemplateImage(_ source: NSImage, pointSize: CGFloat) -> NSImage {
        let side = max(pointSize, 1)
        let size = NSSize(width: side, height: side)
        let rendered = NSImage(size: size)
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1
        )
        rendered.unlockFocus()
        rendered.isTemplate = true
        return rendered
    }

    private static func url(named assetName: String) -> URL? {
        if let resourceDirectoryForTesting {
            let url = resourceDirectoryForTesting.appendingPathComponent("\(assetName).pdf")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return Bundle.main.url(
            forResource: assetName,
            withExtension: "pdf",
            subdirectory: "UsefulLinkIcons"
        ) ?? Bundle.main.url(
            forResource: assetName,
            withExtension: "pdf"
        )
    }

    static func isCachedForTesting(_ assetName: String) -> Bool {
        isSourceCachedForTesting(assetName)
    }

    static func isSourceCachedForTesting(_ assetName: String) -> Bool {
        sourceCache[assetName] != nil
    }

    static func isRenderedCachedForTesting(_ assetName: String, pointSize: CGFloat) -> Bool {
        renderedCache[RenderedKey(assetName: assetName, pointSize: pointSize)] != nil
    }

    static func clearCacheForTesting() {
        sourceCache.removeAll()
        renderedCache.removeAll()
    }

    static func setResourceDirectoryForTesting(_ url: URL?) {
        resourceDirectoryForTesting = url
    }

    private struct RenderedKey: Hashable {
        let assetName: String
        let pointSizeTenths: Int

        init(assetName: String, pointSize: CGFloat) {
            self.assetName = assetName
            self.pointSizeTenths = Int((pointSize * 10).rounded())
        }

        var pointSize: CGFloat {
            CGFloat(pointSizeTenths) / 10
        }
    }

    private static var sourceCache: [String: NSImage] = [:]
    private static var renderedCache: [RenderedKey: NSImage] = [:]
    private static var resourceDirectoryForTesting: URL?
}
