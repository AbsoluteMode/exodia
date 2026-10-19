import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class NotifyRenderTests: XCTestCase {
    func testOffscreenPillAndHistoryFixtures() async throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_NOTIFY_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_NOTIFY_RENDER_DIR for source-matched offscreen visual checks.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures = [("telegram", "Message from Alex", "The build is ready", "#299FD6", "paperplane.fill"),
                        ("warning", "Deployment needs attention", "A deliberately long message that must fit the original left-side slot without overflowing", "#F2A03B", "exclamationmark.triangle.fill")]
        var events: [LocalNotificationEvent] = []
        for (id, title, body, tint, logo) in fixtures {
            let event = LocalNotificationEvent(id: id, source: id, sourceName: id, title: title, body: body,
                link: URL(string: "https://example.com"), timestamp: Date(), customDuration: 8,
                customTint: tint, customLogo: logo)
            events.append(event)
            let view = IslandNotificationPill(event: event, deadline: Date().addingTimeInterval(6), duration: 8)
                .frame(width: 300, height: 48, alignment: .topTrailing)
            try render(view, size: NSSize(width: 300, height: 48), to: directory.appendingPathComponent(id + ".png"))
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let hub = LocalNotificationHub(directory: temporary)
        for event in events { _ = await hub.receive(event) }
        hub.setSuspended(true)
        let supervisor = NotifyScriptSupervisor(directory: temporary, hub: hub)
        try render(NotifyHoverPanel(hub: hub, supervisor: supervisor, onBack: {}),
                   size: NSSize(width: 312, height: 235), to: directory.appendingPathComponent("history.png"))
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
    }
}
