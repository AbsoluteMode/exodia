import XCTest
@testable import Sidekey

final class NotificationCompatibilityTests: XCTestCase {
    func testCardPanelFitsUnnotchedAndNotchedDisplaysAndKeepsTopAlignment() {
        for x: CGFloat in [-1920, 0, 1920] {
            for inset: CGFloat in [0, 38] {
                let screen = IslandScreenDescriptor(uuid: "fixture", frame: NSRect(x: x, y: 0, width: 1920, height: 1080),
                    visibleFrame: NSRect(x: x, y: 0, width: 1920, height: 1055), safeAreaTopInset: inset,
                    auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil)
                let panel = IslandFrameLayout.notificationPanelFrame(on: screen)
                let island = IslandFrameLayout.islandFrame(on: screen)
                XCTAssertGreaterThanOrEqual(panel.height, IslandNotificationPill.pillHeight * IslandNotificationPill.hoverScale)
                XCTAssertEqual(panel.maxY, island.maxY)
                XCTAssertEqual(panel.maxX, island.minX)
                XCTAssertEqual(panel.width, IslandFrameLayout.leftNotificationWidth + IslandNotificationPill.panelLeadingOverflow)
                XCTAssertTrue(screen.frame.contains(panel))
            }
        }
    }

    func testEnlargedCardAndClickAreaFitInsidePanelAndReduceMotionKeepsOriginalSize() {
        let layout = CGRect(x: IslandNotificationPill.panelLeadingOverflow, y: 0,
                            width: IslandNotificationPill.pillMaxWidth, height: IslandNotificationPill.pillHeight)
        let panel = CGRect(x: 0, y: 0,
                           width: IslandFrameLayout.leftNotificationWidth + IslandNotificationPill.panelLeadingOverflow,
                           height: IslandNotificationPill.pillHeight + IslandNotificationPill.panelBottomOverflow)
        let enlarged = IslandNotificationPill.visualFrame(for: layout, hovered: true, reduceMotion: false)
        XCTAssertEqual(enlarged.width, layout.width * 1.03, accuracy: 0.001)
        XCTAssertEqual(enlarged.height, layout.height * 1.03, accuracy: 0.001)
        XCTAssertEqual(enlarged.maxX, layout.maxX)
        XCTAssertEqual(enlarged.minY, layout.minY)
        XCTAssertTrue(panel.contains(enlarged))
        XCTAssertTrue(enlarged.contains(CGPoint(x: layout.minX - 1, y: layout.midY)),
                      "The visible enlarged edge must remain clickable")
        XCTAssertEqual(IslandNotificationPill.visualFrame(for: layout, hovered: false, reduceMotion: false), layout)
        XCTAssertEqual(IslandNotificationPill.visualFrame(for: layout, hovered: true, reduceMotion: true), layout)
    }

    func testClaudeDesktopOnlyOpensAnExactExistingCodeSession() throws {
        let script = NotifyScript(id: "claude", name: "Claude Code", command: ["/bin/echo"])
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

    func testRetiredIconSourceAndPayloadBecomeCardsWithoutLosingLinksOrLabels() throws {
        let source = try JSONDecoder().decode(NotifyScript.self, from: Data(#"{"id":"codex","name":"Codex","command":["/bin/echo"],"presentation":"icon","logo":"codex"}"#.utf8))
        let payload = try JSONDecoder().decode(NotifyPayload.self, from: Data(#"{"id":"done","presentation":"icon","link":"codex://threads/session-123"}"#.utf8))
        let event = try LocalNotificationEvent.make(payload, script: source)
        XCTAssertEqual(event.title, "Codex")
        XCTAssertEqual(event.resolvedDuration, 8)
        XCTAssertEqual(event.customLogo, "codex")
        XCTAssertEqual(event.link?.absoluteString, "codex://threads/session-123")
        let sourceBytes = try JSONEncoder().encode(source)
        XCTAssertFalse(String(decoding: sourceBytes, as: UTF8.self).contains("presentation"))
        var archived = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        archived["presentation"] = "icon"
        let restored = try JSONDecoder().decode(LocalNotificationEvent.self, from: JSONSerialization.data(withJSONObject: archived))
        XCTAssertEqual(restored, event)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(restored), as: UTF8.self).contains("presentation"))
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
