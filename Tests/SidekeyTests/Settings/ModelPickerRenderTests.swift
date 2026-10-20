import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class ModelPickerRenderTests: XCTestCase {
    func testSearchResultsAndEmptyStatesInBothAppearances() throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_MODEL_PICKER_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_MODEL_PICKER_RENDER_DIR for offscreen visual proof")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sections = [PickerSection(account: .openRouter, title: "OpenRouter", options: [
            PickerOption(model: "anthropic/claude-sonnet-5.5", state: .verified, isSelected: false, hint: nil),
            PickerOption(model: "qwen/qwen3.8-27b", state: .new, isSelected: true, hint: nil),
            PickerOption(model: "qwen/qwen3-27b:free", state: .new, isSelected: false, hint: nil),
            PickerOption(model: "qwen/qwen3.8-27b-long-context-instruct-with-a-very-long-identifier",
                         state: .notSupported(reason: "This model cannot serve this feature"),
                         isSelected: false, hint: nil),
        ], refreshFailed: true)]

        let unlisted = PickerSection(account: .server(UUID()), title: "My server", options: [], refreshFailed: false,
                                     acceptsModelName: true)
        for dark in [false, true] {
            for state in ["all", "qwen27", "empty", "no-provider", "unlisted-server"] {
                let query = state == "qwen27" ? "qwen 27" : (state == "empty" ? "missing model" : "")
                let picker = ModelPicker(sections: state == "no-provider" ? [] : (state == "unlisted-server" ? [unlisted] : sections),
                                         missingProviderHint: "Add API key", initialQuery: query,
                                         onSelect: { _, _ in }, onRefresh: {}, onAddKey: {},
                                         onClose: {})
                let host = NSHostingView(rootView: picker.environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = NSSize(width: 440, height: 400)
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                      styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(state)-\(dark ? "dark" : "light").png"))
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
                window.contentView = nil
                window.close()
            }
        }
    }
}
