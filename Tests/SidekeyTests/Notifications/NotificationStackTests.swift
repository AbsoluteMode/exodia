import XCTest
@testable import Sidekey

@MainActor
final class NotificationStackTests: XCTestCase {
    private func event(_ id: String, presentation: NotifyPresentation = .icon) -> LocalNotificationEvent {
        LocalNotificationEvent(id: id, source: "test", sourceName: "Test", title: "Event \(id)", body: "",
            link: URL(string: "codex://threads/\(id)"), timestamp: Date(), customDuration: 2,
            customLogo: "codex", presentation: presentation)
    }
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testBurstKeepsIndividualLinksAndDismissesOnlySelectedLayer() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let hub = LocalNotificationHub(directory: root)
        _ = await hub.receive(event("older")); _ = await hub.receive(event("newer"))
        let duplicate = await hub.receive(event("newer"))
        XCTAssertFalse(duplicate)
        XCTAssertEqual(hub.iconStack.map(\.id), ["newer", "older"])
        XCTAssertEqual(hub.iconStack.map { $0.link?.absoluteString },
            ["codex://threads/newer", "codex://threads/older"])
        XCTAssertEqual(hub.current?.id, "newer")
        hub.dismiss(id: "older")
        XCTAssertFalse(hub.isPresented("older")); XCTAssertTrue(hub.isPresented("newer"))
        XCTAssertEqual(hub.iconStack.count, 1)
        hub.dismiss(id: "stale")
        XCTAssertEqual(hub.current?.id, "newer")
        hub.dismiss()
        XCTAssertNil(hub.current); XCTAssertTrue(hub.iconStack.isEmpty)
        XCTAssertEqual(hub.unreadCount, 2) // Temporary dismissal is not reading history.
    }

    func testCardsSeparateBurstsAndQueuedIconsAppearTogether() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let hub = LocalNotificationHub(directory: root)
        _ = await hub.receive(event("first"))
        _ = await hub.receive(event("card", presentation: .card))
        _ = await hub.receive(event("second")); _ = await hub.receive(event("third"))
        XCTAssertEqual(hub.iconStack.map(\.id), ["first"])
        hub.dismiss()
        XCTAssertEqual(hub.current?.id, "card"); XCTAssertTrue(hub.iconStack.isEmpty)
        hub.dismiss()
        XCTAssertEqual(hub.iconStack.map(\.id), ["third", "second"])
        hub.setSuspended(true)
        XCTAssertNil(hub.current); XCTAssertTrue(hub.iconStack.isEmpty)
        XCTAssertEqual(hub.history.count, 4)
    }

    func testClearAllClearsBurstQueueAndPersistentAttentionButKeepsFutureDelivery() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let hub = LocalNotificationHub(directory: root)
        for index in 0..<40 { _ = await hub.receive(event("item-\(index)")) }
        XCTAssertEqual(hub.iconStack.count, 33) // Same bound as the previous current + 32 queued.
        XCTAssertEqual(hub.history.count, 40)
        await hub.clear()
        XCTAssertNil(hub.current); XCTAssertNil(hub.deadline); XCTAssertTrue(hub.iconStack.isEmpty)
        XCTAssertEqual(hub.unreadCount, 0)
        let restored = LocalNotificationHub(directory: root); await restored.load()
        XCTAssertTrue(restored.history.isEmpty)
        _ = await hub.receive(event("preclear"))
        _ = await hub.receive(event("queued-card", presentation: .card))
        _ = await hub.receive(event("queued-icon"))
        await hub.clear()
        XCTAssertNil(hub.current); XCTAssertTrue(hub.iconStack.isEmpty)
        _ = await hub.receive(event("fresh"))
        XCTAssertEqual(hub.unreadCount, 1)
        hub.dismiss()
        let unattended = LocalNotificationHub(directory: root); await unattended.load()
        XCTAssertEqual(unattended.unreadCount, 1)
        await unattended.markRead()
        let seen = LocalNotificationHub(directory: root); await seen.load()
        XCTAssertEqual(seen.unreadCount, 0); XCTAssertEqual(seen.history.count, 1)
    }

    func testNewEventWhileHoveredRestartsBurstLifetimeAndExpiryClearsWholeStack() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let hub = LocalNotificationHub(directory: root)
        _ = await hub.receive(event("first"))
        hub.setHovered(true)
        _ = await hub.receive(event("second"))
        try await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertEqual(hub.iconStack.count, 2)
        hub.setHovered(false)
        XCTAssertGreaterThan(hub.deadline?.timeIntervalSinceNow ?? 0, 1.8)
        try await Task.sleep(nanoseconds: 2_150_000_000)
        XCTAssertNil(hub.current); XCTAssertTrue(hub.iconStack.isEmpty)
        XCTAssertEqual(hub.history.count, 2)
    }

    func testHistoryKeepsNewestFiveHundredIncludingUnreadAfterRelaunch() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let hub = LocalNotificationHub(directory: root)
        hub.setSuspended(true)
        for index in 0..<502 { _ = await hub.receive(event("item-\(index)")) }
        let restored = LocalNotificationHub(directory: root); await restored.load()
        XCTAssertEqual(restored.history.count, 500); XCTAssertEqual(restored.unreadCount, 500)
        XCTAssertEqual(restored.history.first?.id, "item-501")
        XCTAssertEqual(restored.history.last?.id, "item-2")
        XCTAssertNil(restored.current)
    }

    func testClickingHoveredLeftCardDoesNotLeaveNextRightIconPaused() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let hub = LocalNotificationHub(directory: root)
        _ = await hub.receive(event("left", presentation: .card))
        hub.setHovered(true)
        _ = await hub.receive(event("right"))
        hub.dismiss()
        XCTAssertEqual(hub.current?.id, "right")
        try await Task.sleep(nanoseconds: 2_150_000_000)
        XCTAssertNil(hub.current)
    }

    func testHoveredLayersStayInsideWingAndSeparateEnoughToSelect() {
        for count in 1...3 {
            let centers = (0..<count).map {
                IslandNotificationStackContent.centerX(index: $0, count: count, hovered: true)
            }
            XCTAssertTrue(centers.allSatisfy { $0 - 14.7 >= 0 && $0 + 14.7 <= 70 })
            if count > 1 {
                for index in 1..<count { XCTAssertGreaterThanOrEqual(centers[index - 1] - centers[index], 16) }
            }
        }
    }
}
