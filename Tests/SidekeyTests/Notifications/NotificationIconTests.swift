import XCTest
@testable import Sidekey

final class NotificationIconContractTests: XCTestCase {
    func testClaudeDesktopOnlyOpensAnExactExistingCodeSession() throws {
        let script = NotifyScript(id: "claude", name: "Claude Code", command: ["/bin/echo"], presentation: .icon)
        let session = "local_00000000-1111-2222-3333-444444444444"
        let link = "claude://code/continue?session=\(session)"
        func payload(_ link: String) throws -> NotifyPayload {
            try JSONDecoder().decode(NotifyPayload.self, from: JSONSerialization.data(withJSONObject: ["link": link]))
        }
        XCTAssertEqual(try LocalNotificationEvent.make(payload(link), script: script).link?.absoluteString, link)
        for invalid in ["claude://code/new", "claude://code/continue?session=last",
                        "claude://code/continue?session=unknown", "claude://code/continue?session=\(session)&q=run",
                        "claude://code/continue?session=\(session)&session=\(session)",
                        "claude://user@code/continue?session=\(session)", link + "#fragment",
                        "claude://claude.ai/new?q=run"] {
            XCTAssertThrowsError(try LocalNotificationEvent.make(payload(invalid), script: script), invalid)
        }
    }

    func testIconSourceNeedsNoTextAndDefaultsToFiveSeconds() throws {
        let script = NotifyScript(id: "codex", name: "Codex", command: ["/bin/echo"],
                                  logo: "codex", presentation: .icon)
        let payload = try JSONDecoder().decode(NotifyPayload.self,
            from: Data(#"{"id":"done","link":"codex://threads/session-123"}"#.utf8))
        let event = try LocalNotificationEvent.make(payload, script: script)
        XCTAssertEqual(event.resolvedPresentation, .icon)
        XCTAssertEqual(event.title, "Codex")
        XCTAssertEqual(event.body, "")
        XCTAssertEqual(event.resolvedDuration, 5)
        XCTAssertEqual(event.customLogo, "codex")
        XCTAssertEqual(event.link?.absoluteString, "codex://threads/session-123")
        let restored = try JSONDecoder().decode(LocalNotificationEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(restored, event)
    }

    func testPresentationOverridesSourceWithoutChangingExistingCards() throws {
        let source = NotifyScript(id: "source", name: "Source", command: ["/bin/echo"], presentation: .icon)
        let payload = try JSONDecoder().decode(NotifyPayload.self, from: Data(#"{"title":"A card","presentation":"card"}"#.utf8))
        XCTAssertEqual(try LocalNotificationEvent.make(payload, script: source).resolvedPresentation, .card)
        XCTAssertEqual(try LocalNotificationEvent.make(payload, script: source).resolvedDuration, 8)
        var card = source; card.presentation = nil
        let empty = try JSONDecoder().decode(NotifyPayload.self, from: Data("{}".utf8))
        XCTAssertThrowsError(try LocalNotificationEvent.make(empty, script: card))
        XCTAssertThrowsError(try JSONDecoder().decode(NotifyPayload.self, from: Data(#"{"presentation":"unknown"}"#.utf8)))
        let old = LocalNotificationEvent(id: "old", source: "source", sourceName: "Source", title: "Old card",
                                         body: "", link: nil, timestamp: Date())
        let bytes = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("presentation"))
        let restored = try JSONDecoder().decode(LocalNotificationEvent.self, from: bytes)
        XCTAssertEqual(restored.resolvedPresentation, .card)
        XCTAssertEqual(restored.resolvedDuration, 8)
    }

    func testCodexLinksOnlyAllowExistingSessionNavigation() throws {
        let script = NotifyScript(id: "x", name: "X", command: ["/bin/echo"])
        for link in ["codex://plugins/install/test", "codex://new?prompt=run", "codex://threads/new",
                     "codex://threads/id?prompt=run", "codex://threads/a/b", "codex://user@threads/id"] {
            let data = try JSONSerialization.data(withJSONObject: ["title": "X", "link": link])
            let payload = try JSONDecoder().decode(NotifyPayload.self, from: data)
            XCTAssertThrowsError(try LocalNotificationEvent.make(payload, script: script), link)
        }
    }
}

@MainActor
final class NotificationIconBehaviorTests: XCTestCase {
    func testIconKeepsSelectedDisplayAndAlignsWithTheIsland() {
        for x: CGFloat in [-1920, 0, 1920] {
            let screen = IslandScreenDescriptor(uuid: "test", frame: NSRect(x: x, y: 0, width: 1920, height: 1080),
                visibleFrame: NSRect(x: x, y: 0, width: 1920, height: 1055), safeAreaTopInset: 0,
                auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil)
            let icon = IslandFrameLayout.notificationIconPanelFrame(on: screen)
            let island = IslandFrameLayout.islandFrame(on: screen)
            XCTAssertTrue(screen.frame.contains(icon))
            XCTAssertEqual(icon.minX, island.maxX - IslandFrameLayout.rightSideWidth)
            XCTAssertEqual(icon.maxX, island.maxX)
            XCTAssertEqual(icon.height, island.height)
            XCTAssertEqual(icon.maxY, island.maxY)
        }
    }

    func testShakeIsBoundedAndEndsAtFiveSeconds() {
        XCTAssertEqual(IslandNotificationIcon.rotation(elapsed: -1), 0)
        XCTAssertEqual(IslandNotificationIcon.rotation(elapsed: 5), 0)
        XCTAssertEqual(IslandNotificationIcon.rotation(elapsed: 15), 0)
        let samples = stride(from: 0.0, to: 5.0, by: 0.01).map(IslandNotificationIcon.rotation)
        XCTAssertTrue(samples.allSatisfy { abs($0) <= 7 })
        XCTAssertTrue(samples.contains { abs($0) > 3 })
    }

    func testIconAutomaticallyExpiresButHoverPausesAndCardStillAdvances() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = LocalNotificationHub(directory: root)
        let script = NotifyScript(id: "source", name: "Source", command: ["/bin/echo"])
        let payload = try JSONDecoder().decode(NotifyPayload.self,
            from: Data(#"{"presentation":"icon","duration":2,"logo":"codex"}"#.utf8))
        let icon = try LocalNotificationEvent.make(payload, script: script)
        _ = await hub.receive(icon)
        hub.setHovered(true)
        try await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertEqual(hub.current?.id, icon.id)
        let cardPayload = try JSONDecoder().decode(NotifyPayload.self, from: Data(#"{"title":"A card"}"#.utf8))
        let card = try LocalNotificationEvent.make(cardPayload, script: script)
        _ = await hub.receive(card)
        hub.setHovered(false)
        try await Task.sleep(nanoseconds: 2_150_000_000)
        XCTAssertEqual(hub.current?.id, card.id)
        XCTAssertEqual(hub.current?.resolvedPresentation, .card)
        XCTAssertEqual(hub.history.first(where: { $0.id == icon.id })?.resolvedPresentation, .icon)
        hub.setSuspended(true)
    }
}
