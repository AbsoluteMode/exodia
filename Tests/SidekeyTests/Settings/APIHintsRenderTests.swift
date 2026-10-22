import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// No app launch, keys or network. Review both scroll extremes so an added
/// offer cannot silently disappear below a fixed-size grid or footer.
@MainActor
final class APIHintsRenderTests: XCTestCase {
    func testOffscreenOfferLayoutsAndScrollReachability() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_API_HINTS_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_API_HINTS_RENDER_DIR for API Hints review images")
        }
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        ProviderBrandIconAsset.clearCacheForTesting()
        ProviderBrandIconAsset.setResourceDirectoryForTesting(root.appendingPathComponent("Resources/UsefulLinkIcons"))
        defer {
            ProviderBrandIconAsset.clearCacheForTesting()
            ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
        }
        for embedded in [false, true] {
            for dark in [false, true] {
                for width in [440.0, 560.0, 760.0] {
                    let host = NSHostingView(rootView: APIHintsView(onAddKey: {}, onClose: {}, embedded: embedded)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 650)
                    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 650),
                                          styleMask: .borderless, backing: .buffered, defer: true)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    host.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.bounds.width, width)
                    XCTAssertEqual(host.bounds.height, 650)
                    let scroll = try XCTUnwrap(Self.scrollViews(in: host).first)
                    let document = try XCTUnwrap(scroll.documentView)
                    XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
                    let end = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    for bottom in [false, true] {
                        let y = bottom == document.isFlipped ? end : 0
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        host.layoutSubtreeIfNeeded()
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: image)
                        let name = "api-hints-\(embedded ? "embedded" : "sheet")-\(dark ? "dark" : "light")-\(Int(width))-\(bottom ? "bottom" : "top").png"
                        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name))
                        XCTAssertFalse(window.isVisible)
                        XCTAssertFalse(window.isKeyWindow)
                    }
                }
            }
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
