import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class CalendarHoverTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let calendar = Calendar.current
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21))! }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "calendar.hover.test." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
        PlannerURLProtocol.handler = nil; PlannerURLProtocol.delay = 0
    }

    private func makeModel(now: (() -> Date)? = nil, activity: @escaping (Bool) -> Void = { _ in }) -> CalendarHoverModel {
        CalendarHoverModel(store: PlannerStore(url: directory.appendingPathComponent("planner.json")),
            connections: CalendarConnections(defaults: defaults), now: now ?? { self.day.addingTimeInterval(36000) },
            activityChanged: activity)
    }

    func testEveryOpeningResetsToTodayAndInlineNavigationDoesNotResetDay() {
        var clock = day.addingTimeInterval(36000)
        var activity: [Bool] = []
        let model = makeModel(now: { clock }, activity: { activity.append($0) })
        model.begin(); XCTAssertEqual(model.selectedDay, day); XCTAssertTrue(model.isToday)
        model.moveDay(1)
        let tomorrow = model.selectedDay
        model.page = .providers
        model.begin()
        XCTAssertEqual(model.page, .providers); XCTAssertEqual(model.selectedDay, tomorrow)
        model.end(); model.begin()
        XCTAssertEqual(model.page, .agenda); XCTAssertEqual(model.selectedDay, day)
        model.page = .event("missing"); model.openToday()
        XCTAssertEqual(model.page, .agenda)
        clock = calendar.date(byAdding: .day, value: 1, to: clock)!
        model.dayChanged()
        XCTAssertEqual(model.selectedDay, tomorrow)
        model.moveDay(-1); model.dayChanged()
        XCTAssertEqual(model.selectedDay, day, "Midnight must not move a deliberately selected day")
        model.end(); XCTAssertEqual(activity, [true, false, true, false])
    }

    func testDayAgendaIncludesSpanningEventsAndExclusiveEndAndHonorsVisibility() {
        let model = makeModel(); model.begin()
        let previous = day.addingTimeInterval(-3600)
        let spanning = PlannerEvent(title: "Spanning midnight", start: previous, end: day.addingTimeInterval(1800))
        let ended = PlannerEvent(title: "Ends exactly at midnight", start: previous, end: day)
        let timed = PlannerEvent(title: "Timed", start: day.addingTimeInterval(36000), end: day.addingTimeInterval(37800))
        let allDay = PlannerEvent(title: "All day", start: day,
            end: calendar.date(byAdding: .day, value: 1, to: day)!, allDay: true)
        for event in [timed, ended, spanning, allDay] { XCTAssertTrue(model.store.saveEvent(event)) }
        XCTAssertEqual(model.events.map(\.event.title), ["All day", "Spanning midnight", "Timed"])
        model.connections.setVisible(false, feedID: "local"); XCTAssertTrue(model.events.isEmpty)
        model.connections.setVisible(true, feedID: "local"); XCTAssertEqual(model.events.count, 3)
        model.moveDay(1); XCTAssertTrue(model.events.isEmpty)
    }

    func testMergedConnectedFeedsRespectHiddenCalendarsBeforeDeduplication() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlannerURLProtocol.self]
        let http = CalendarHTTP(session: URLSession(configuration: configuration))
        let credentials = PlannerMemoryCredentials()
        let oauth = CalendarOAuthClient(http: http, storage: credentials)
        let connections = CalendarConnections(defaults: defaults, oauth: oauth, http: http)
        let account = ConnectedCalendarAccount(id: UUID(), provider: .google, label: "Synthetic Google")
        try credentials.save(CalendarCredential(provider: .google, clientID: "fixture", accessToken: "fixture",
            refreshToken: "fixture", expiresAt: .distantFuture), id: account.id, backupRelevant: false)
        try connections.add(account)
        let start = CalendarDateCodec.string(day.addingTimeInterval(36000))
        let end = CalendarDateCodec.string(day.addingTimeInterval(37800))
        PlannerURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("calendarList") {
                return (200, ["items": [["id": "one", "summary": "One"], ["id": "two", "summary": "Two"]]])
            }
            return (200, ["items": [["id": "shared", "iCalUID": "same-occurrence", "summary": "Shared event",
                "start": ["dateTime": start], "end": ["dateTime": end]]]])
        }
        let model = CalendarHoverModel(store: PlannerStore(url: directory.appendingPathComponent("planner.json")),
            connections: connections, now: { self.day })
        model.begin(); await connections.refresh(interval: model.interval)
        XCTAssertTrue(connections.errors.isEmpty)
        XCTAssertEqual(model.events.count, 1)
        let one = try XCTUnwrap(connections.feeds.first(where: { $0.remoteID == "one" }))
        let two = try XCTUnwrap(connections.feeds.first(where: { $0.remoteID == "two" }))
        connections.setVisible(false, feedID: one.id)
        XCTAssertEqual(model.events.first?.feedID, two.id)
        connections.setVisible(false, feedID: two.id); XCTAssertTrue(model.events.isEmpty)
        try await connections.remove(account); XCTAssertTrue(model.events.isEmpty)
        XCTAssertNil(try credentials.read(account.id))
    }

    func testTileHotkeyAndLinkUseSameInlineCalendarAndHitArea() {
        var windows = 0
        var actions = IslandActions.noOp; actions.openCalendar = { windows += 1 }
        let effect = HoverSlotRouter.effect(for: .calendar)
        XCTAssertEqual(effect, .openPanel(.calendar)); XCTAssertTrue(effect.requiresExpansion)
        effect.invoke(on: actions); XCTAssertEqual(windows, 0)
        XCTAssertEqual(HoverToolRegistry.info(for: .calendar).kind, .inlinePanel)
        XCTAssertEqual(WhytapLink.destination(for: .calendar), .hoverPanel(.calendar))
        XCTAssertTrue(IslandHoverPanelMode.calendar.needsKeyboardFocus)
        XCTAssertTrue(IslandView.menuStaysOpen(.calendar, glance: false))
        let height = IslandView.hoverPanelHeight(for: .calendar, musicActive: false)
        XCTAssertEqual(height, CalendarHoverView.contentHeight + IslandDropModeControl.detachedPanelGap)
        for width: CGFloat in [310, 360, 500] {
            let pill = CGRect(x: 500, y: 600, width: width, height: 38)
            let zone = IslandHoverPanelHitZone(compactFrame: pill, bandHeight: height)
            XCTAssertFalse(IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                cursor: CGPoint(x: pill.midX, y: zone.drawerFrame.minY + 1), activeFrames: zone.activeFrames))
        }
    }

    func testOffscreenCalendarHoverFixtures() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_CALENDAR_HOVER_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_CALENDAR_HOVER_RENDER_DIR for synthetic offscreen Calendar fixtures")
        }
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let model = makeModel(); model.begin()
        let info: [String: Any] = ["WhytapCalendarOAuthClients": [
            "google": ["clientID": "fixture"], "microsoft": ["clientID": "fixture"]]]
        for width: CGFloat in [310, 360, 500] {
            try await render(model, page: .agenda, name: "empty", width: width, info: info, destination: destination)
            try await render(model, page: .providers, name: "providers", width: width, info: info, destination: destination)
            try await render(model, page: .connect(.google), name: "google-pending", width: width, info: info, destination: destination)
            try await render(model, page: .connect(.microsoft), name: "outlook-connect", width: width, info: info, destination: destination)
            try await render(model, page: .connect(.apple), name: "apple-connect", width: width, info: info, destination: destination)
        }
        for index in 0..<10 {
            let event = PlannerEvent(title: index == 0 ? "Очень длинное название встречи — обсуждение запуска календаря и следующих шагов с командой" : "Meeting \(index)",
                start: day.addingTimeInterval(Double(32400 + index * 1800)), end: day.addingTimeInterval(Double(34200 + index * 1800)),
                location: "Studio · переговорная на втором этаже", notes: String(repeating: "Useful details about the meeting. ", count: 12),
                meetingURL: URL(string: "https://example.invalid/meeting"))
            XCTAssertTrue(model.store.saveEvent(event))
        }
        let first = try XCTUnwrap(model.events.first)
        for width: CGFloat in [310, 360, 500] {
            try await render(model, page: .agenda, name: "agenda-long-list", width: width, info: info, destination: destination)
            try await render(model, page: .event(first.id), name: "details", width: width, info: info, destination: destination)
            try await render(model, page: .sources, name: "sources", width: width, info: info, destination: destination)
        }
        XCTAssertTrue(model.connections.beginConnecting(provider: .microsoft))
        try await render(model, page: .connect(.microsoft), name: "busy", width: 310, info: info, destination: destination)
        model.connections.endConnecting()
        try await render(model, page: .agenda, name: "reduced-motion", width: 310, info: info, destination: destination, reduceMotion: true)
    }

    private func render(_ model: CalendarHoverModel, page: CalendarHoverModel.Page, name: String,
                        width: CGFloat, info: [String: Any], destination: URL, reduceMotion: Bool = false) async throws {
        model.begin(); model.page = page
        let host = NSHostingView(rootView: CalendarHoverView(model: model, liveUpdates: false, configurationInfo: info, onBack: {})
            .background(Color(white: 0.12)).environment(\.colorScheme, .dark)
            .transaction { if reduceMotion { $0.disablesAnimations = true } })
        let size = NSSize(width: width, height: CalendarHoverView.contentHeight)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size); window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: destination.appendingPathComponent("\(name)-\(Int(width)).png"))
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
    }
}
