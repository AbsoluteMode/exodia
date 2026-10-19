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
        // SwiftPM doesn't package the production assets. Load the same PDFs
        // directly for this isolated fixture, without touching the user's logos.
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let loadImage: (String) -> NSImage? = { name in
            NSImage(contentsOf: checkout.appendingPathComponent("Resources/UsefulLinkIcons/\(name).pdf"))
        }
        for name in ["codex", "claude-code"] {
            XCTAssertNotNil(loadImage(name))
        }
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
        for (name, logo, tint) in [("codex", "codex", "#373A42"), ("claude", "claude-code", "#C87554")] {
            let event = LocalNotificationEvent(id: name, source: name, sourceName: name, title: "Waiting for your answer",
                body: "", link: URL(string: "https://example.com/session"), timestamp: Date(),
                customTint: tint, customLogo: logo, presentation: .icon)
            for hovered in [false, true] {
                let icon = IslandNotificationIconContent(event: event, hovered: hovered, rotation: 0,
                    onTap: {}, onDismiss: {}, imageLoader: loadImage)
                try render(icon, size: NSSize(width: 70, height: 38),
                    to: directory.appendingPathComponent("icon-\(name)-\(hovered ? "hover" : "idle").png"))
            }
        }
        let stacked = (0..<33).map { index in
            LocalNotificationEvent(id: "stack-\(index)", source: "agent", sourceName: "Agent", title: "Finished",
                body: "", link: nil, timestamp: Date(), customTint: index.isMultiple(of: 2) ? "#373A42" : "#C87554",
                customLogo: index.isMultiple(of: 2) ? "codex" : "claude-code", presentation: .icon)
        }
        for count in [2, 3, 33] {
            for hovered in [false, true] {
                for height: CGFloat in [28, 38] {
                    let view = IslandNotificationStackContent(events: Array(stacked.prefix(count)), height: height,
                        hovered: hovered, rotation: 0, onTap: { _ in }, onDismiss: { _ in }, imageLoader: loadImage)
                    try render(view, size: NSSize(width: 70, height: height),
                        to: directory.appendingPathComponent("stack-\(count)-\(Int(height))-\(hovered ? "hover" : "idle").png"))
                }
            }
        }
        let comparison = VStack(spacing: 14) {
            ForEach([2, 3, 33], id: \.self) { count in
                HStack(spacing: 12) {
                    Text("\(count)").frame(width: 25)
                    ForEach([false, true], id: \.self) { hovered in
                        IslandNotificationStackContent(events: Array(stacked.prefix(count)), hovered: hovered,
                            rotation: 0, onTap: { _ in }, onDismiss: { _ in }, imageLoader: loadImage)
                            .scaleEffect(3).frame(width: 210, height: 114)
                    }
                }
            }
        }.padding(14).foregroundStyle(.white).background(Color(white: 0.13))
        try render(comparison, size: NSSize(width: 510, height: 400),
            to: directory.appendingPathComponent("stack-comparison.png"))
        let tools = HStack {
            IslandHoverPanelControl(title: "Notify", systemImage: "bell", pdfResource: nil, label: nil,
                circleSize: 30, accessibilityLabel: "Notify", showsDot: true, action: {})
            IslandHoverPanelControl(title: "Monitor", systemImage: "chart.xyaxis.line", pdfResource: nil, label: nil,
                circleSize: 30, accessibilityLabel: "Monitor", action: {})
        }.padding(8).background(Color(white: 0.08))
        try render(tools, size: NSSize(width: 210, height: 70),
            to: directory.appendingPathComponent("notify-attention-monitor-quiet.png"))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let hub = LocalNotificationHub(directory: temporary)
        for event in events { _ = await hub.receive(event) }
        hub.setSuspended(true)
        let supervisor = NotifyScriptSupervisor(directory: temporary, hub: hub)
        try render(NotifyHoverPanel(hub: hub, supervisor: supervisor, onBack: {}),
                   size: NSSize(width: 312, height: 235), to: directory.appendingPathComponent("history.png"))
        await hub.clear()
        try render(NotifyHoverPanel(hub: hub, supervisor: supervisor, onBack: {}),
                   size: NSSize(width: 312, height: 235), to: directory.appendingPathComponent("history-cleared.png"))

        try render(settings(supervisor), size: NSSize(width: 760, height: 560),
                   to: directory.appendingPathComponent("settings-empty.png"))
        let registry = temporary.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        let sources = [
            NotifyScript(id: "telegram", name: "Telegram · selected chats", command: ["/bin/sleep", "30"], tint: "#299FD6", logo: "paperplane.fill"),
            NotifyScript(id: "builds", name: "Build results", command: ["/bin/sleep", "30"], enabled: false, tint: "#F2A03B", logo: "hammer.fill")
        ]
        for source in sources {
            try JSONEncoder().encode(source).write(to: registry.appendingPathComponent(source.id + ".json"))
        }
        supervisor.start()
        defer { supervisor.stop() }
        for _ in 0..<100 where supervisor.sources.count != 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(supervisor.sources.count, 2)
        try render(settings(supervisor), size: NSSize(width: 760, height: 560),
                   to: directory.appendingPathComponent("settings-sources.png"))
        supervisor.setPresentation(.icon, id: "telegram")
        XCTAssertEqual(try JSONDecoder().decode(NotifyScript.self, from: Data(contentsOf: registry.appendingPathComponent("telegram.json"))).presentation, .icon)
        try render(settings(supervisor), size: NSSize(width: 760, height: 560),
                   to: directory.appendingPathComponent("settings-small.png"))
        supervisor.setEnabled(false, id: "telegram")
        XCTAssertFalse(try JSONDecoder().decode(NotifyScript.self, from: Data(contentsOf: registry.appendingPathComponent("telegram.json"))).enabled)
        try render(settings(supervisor), size: NSSize(width: 760, height: 560),
                   to: directory.appendingPathComponent("settings-disabled.png"))
    }
    private func settings(_ supervisor: NotifyScriptSupervisor) -> some View {
        SettingsNotificationsView(supervisor: supervisor)
            .background(Color(white: 0.12)).environment(\.colorScheme, .dark)
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
