import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class TranslationRenderTests: XCTestCase {
    func testOffscreenTranslationStates() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_TRANSLATION_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTap translation render directory for offscreen visual checks.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = TextTranslationModel(makeService: { FixtureTranslator() })
        let audio = FixtureSubtitleAudio()
        let upstream = FixtureSubtitleUpstream()
        let subtitles = LiveSubtitleModel(makeAudio: { audio }, open: { _ in upstream }, makeService: { FixtureTranslator() })
        let presentation = TranslationWindowController.Presentation()
        let view = TranslationView(text: text, subtitles: subtitles, presentation: presentation, openSettings: { _ in })
            .environment(\.colorScheme, .dark)
        try render(view, size: NSSize(width: 620, height: 610), to: directory.appendingPathComponent("text-empty.png"))
        text.input = "Could you send me the latest version?\nI would like to review the changes before our call."
        await text.translate()?.value
        try render(view, size: NSSize(width: 620, height: 610), to: directory.appendingPathComponent("text-result.png"))
        try render(view, size: NSSize(width: 480, height: 540), to: directory.appendingPathComponent("text-narrow.png"))
        presentation.mode = .subtitles
        try render(view, size: NSSize(width: 620, height: 400), to: directory.appendingPathComponent("subtitles-empty.png"))
        let task = subtitles.start()
        for _ in 0..<100 where subtitles.phase != .listening { try await Task.sleep(for: .milliseconds(5)) }
        upstream.pair.continuation.yield(.final("Let’s go through the changes together. Everything is ready for the next release."))
        for _ in 0..<100 where subtitles.lines.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        subtitles.stop()
        await task?.value
        try render(view, size: NSSize(width: 620, height: 400), to: directory.appendingPathComponent("subtitles-result.png"))
        try render(view, size: NSSize(width: 480, height: 340), to: directory.appendingPathComponent("subtitles-narrow.png"))
        let failed = TextTranslationModel(makeService: { throw OpenRouterLLMError.notConfigured })
        failed.input = "hello"
        await failed.translate()?.value
        presentation.mode = .text
        try render(TranslationView(text: failed, subtitles: subtitles, presentation: presentation, openSettings: { _ in })
            .environment(\.colorScheme, .dark), size: NSSize(width: 480, height: 540),
            to: directory.appendingPathComponent("text-setup.png"))
    }

    private func render<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
