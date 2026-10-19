import XCTest
@testable import Sidekey

final class ScriptNotificationContractTests: XCTestCase {
    private let script = NotifyScript(id: "example", name: "Example", command: ["/bin/zsh"])
    func testOptionalSourceFieldsDefaultWithoutRequiringBoilerplate() throws {
        let source = try JSONDecoder().decode(NotifyScript.self, from: Data(##"{"id":"example","name":"Example","command":["/bin/zsh"]}"##.utf8))
        try source.validate(); XCTAssertTrue(source.enabled); XCTAssertNil(source.intervalSeconds)
    }
    func testArbitrarySourceCarriesPresentationAndScopedStableID() throws {
        var source = script; source.tint = "#123456"; source.logo = "paperplane.fill"
        let payload = try JSONDecoder().decode(NotifyPayload.self, from: Data(##"{"id":"42","title":"A message","body":"Hello","tint":"#ABCDEF","logo":"star.fill","duration":999}"##.utf8))
        let event = try LocalNotificationEvent.make(payload, script: source)
        XCTAssertEqual(event.id, "example:42"); XCTAssertEqual(event.customTint, "#ABCDEF")
        XCTAssertEqual(event.customLogo, "star.fill"); XCTAssertEqual(event.customDuration, 60); XCTAssertNil(event.link)
    }
    func testMalformedPresentationAndExecutableLinksAreRejected() throws {
        for value in [#"{"title":"x","tint":"red"}"#, #"{"title":"x","logo":"../secret"}"#,
                      #"{"title":"x","link":"file:///tmp/test"}"#, #"{"title":"x","link":"javascript:alert(1)"}"#, #"{"title":" "}"#] {
            let payload = try JSONDecoder().decode(NotifyPayload.self, from: Data(value.utf8))
            XCTAssertThrowsError(try LocalNotificationEvent.make(payload, script: script))
        }
    }
    func testDecoderHandlesPartialLinesAndRecoversAfterOversizeOrInvalidLine() throws {
        var decoder = NotifyLineDecoder()
        XCTAssertTrue(decoder.append(Data(##"{"title":"hel"##.utf8)).isEmpty)
        let complete = decoder.append(Data("lo\"}\nnot-json\n".utf8))
        XCTAssertEqual(try complete[0].get().title, "hello"); XCTAssertThrowsError(try complete[1].get())
        var oversized = Data(repeating: 120, count: NotifyLineDecoder.maxLineBytes + 100)
        oversized.append(Data("\n{\"title\":\"valid\"}\n".utf8))
        let recovered = decoder.append(oversized)
        XCTAssertEqual(recovered.count, 2); XCTAssertThrowsError(try recovered[0].get())
        XCTAssertEqual(try recovered[1].get().title, "valid")
    }
    func testConfigurationRejectsShellStringsAndUnsafeRegistryIDs() {
        for source in [NotifyScript(id: "../bad", name: "x", command: ["/bin/sh"]),
                       NotifyScript(id: "x", name: "x", command: ["echo hello"]),
                       NotifyScript(id: "x", name: "x", command: ["/bin/sh"], intervalSeconds: 0)] {
            XCTAssertThrowsError(try source.validate())
        }
    }
    func testRegistryExcludesSymlinksAndPreservesOtherSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let good = root.appendingPathComponent("example.json")
        try JSONEncoder().encode(script).write(to: good)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.json"), withDestinationURL: good)
        let (sources, errors) = try NotifyRegistry.read(root)
        XCTAssertEqual(sources.map(\.id), ["example"]); XCTAssertEqual(errors, ["linked.json"])
    }
}

@MainActor
final class LocalNotificationHubTests: XCTestCase {
    func testHistoryRestoresColorLogoAndDedupWithoutReplayingPills() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = NotifyScript(id: "test", name: "Test", command: ["/bin/sh"], tint: "#12ABEF", logo: "star.fill")
        let payload = try JSONDecoder().decode(NotifyPayload.self, from: Data(##"{"id":"42","title":"Hello"}"##.utf8))
        let event = try LocalNotificationEvent.make(payload, script: script)
        let hub = LocalNotificationHub(directory: root)
        let accepted = await hub.receive(event); XCTAssertTrue(accepted)
        XCTAssertEqual(hub.current?.id, "test:42")
        let duplicate = await hub.receive(event); XCTAssertFalse(duplicate)
        let restored = LocalNotificationHub(directory: root); await restored.load()
        XCTAssertNil(restored.current); XCTAssertEqual(restored.history.first?.customTint, "#12ABEF")
        XCTAssertEqual(restored.history.first?.customLogo, "star.fill"); XCTAssertEqual(restored.unreadCount, 1)
        await restored.markRead(); XCTAssertEqual(restored.unreadCount, 0)
        hub.setSuspended(true)
    }
    func testCorruptHistoryIsPreservedAndEventDoesNotPretendToDeliver() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("history.json"), bytes = Data("broken".utf8)
        try bytes.write(to: file)
        let hub = LocalNotificationHub(directory: root)
        await hub.load(); XCTAssertNotNil(hub.error)
        await hub.clear(); XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testQueueAdvancesAndSuspensionClearsVisibleAndPendingEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = LocalNotificationHub(directory: root)
        let script = NotifyScript(id: "x", name: "X", command: ["/bin/sh"])
        for id in ["1", "2"] {
            let payload = try JSONDecoder().decode(NotifyPayload.self, from: Data("{\"id\":\"\(id)\",\"title\":\"Test\"}".utf8))
            _ = await hub.receive(try LocalNotificationEvent.make(payload, script: script))
        }
        XCTAssertEqual(hub.current?.id, "x:1"); hub.dismiss(); XCTAssertEqual(hub.current?.id, "x:2")
        hub.setSuspended(true); XCTAssertNil(hub.current); XCTAssertEqual(hub.history.count, 2)
    }
    func testNotifyRoutingAndOriginalLeftGeometry() {
        XCTAssertEqual(HoverSlotRouter.effect(for: .notifs), .openPanel(.notifications))
        XCTAssertEqual(HoverToolRegistry.info(for: .notifs).title, "Notify")
        XCTAssertTrue(IslandHoverToolSearch.results(for: "уведомления").contains(.notifs))
        XCTAssertLessThanOrEqual(IslandNotificationPill.pillMaxWidth, IslandNotificationPill.availableSlotWidth)
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let pill = IslandFrameLayout.notificationPanelFrame(frame: frame, visibleFrame: visible, safeAreaTopInset: 38,
                                                          auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil)
        let island = IslandFrameLayout.islandFrame(frame: frame, visibleFrame: visible, safeAreaTopInset: 38,
                                                   auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil)
        XCTAssertEqual(pill.maxX, island.minX); XCTAssertEqual(pill.maxY, island.maxY)
    }
}
