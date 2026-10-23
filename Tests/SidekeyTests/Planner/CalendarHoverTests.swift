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
        let connections = CalendarConnections(defaults: defaults)
        return CalendarHoverModel(store: PlannerStore(url: directory.appendingPathComponent("planner.json")),
            connections: connections, now: now ?? { self.day.addingTimeInterval(36000) },
            activityChanged: activity, connectionFlow: CalendarConnectionFlow(connections: connections, googleReview: { false }))
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

    func testHoverConnectionSurvivesUnmountReopenAndCommitsOnce() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlannerURLProtocol.self]
        let http = CalendarHTTP(session: URLSession(configuration: configuration))
        let credentials = PlannerMemoryCredentials()
        let connections = CalendarConnections(defaults: defaults,
            oauth: CalendarOAuthClient(http: http, storage: credentials), http: http)
        let pending = AsyncThrowingStream<(code: String, redirect: String), Error>.makeStream()
        var activity: [Bool] = []
        let flow = CalendarConnectionFlow(connections: connections, activityChanged: { activity.append($0) }, authorize: { _, _, _, _ in
            var iterator = pending.stream.makeAsyncIterator()
            guard let result = try await iterator.next() else { throw CancellationError() }
            return result
        })
        defer { pending.continuation.finish(); flow.cancel() }
        let model = CalendarHoverModel(store: PlannerStore(url: directory.appendingPathComponent("planner.json")),
            connections: connections, now: { self.day }, connectionFlow: flow)
        let info: [String: Any] = ["WhytapCalendarOAuthClients": ["microsoft": ["clientID": "fixture"]]]
        var completed = 0
        model.begin()
        XCTAssertTrue(model.connect(.microsoft, info: info, onSuccess: { completed += 1 }))
        XCTAssertFalse(model.connect(.google, info: info), "A second click must not start or replace the active flow")
        XCTAssertEqual(flow.lastProvider, .microsoft)
        model.openToday()
        XCTAssertEqual(model.page, .providers, "Connection starts without an intermediate form")
        _ = NSApplication.shared
        let host = NSHostingView(rootView: CalendarHoverView(model: model, liveUpdates: false,
            configurationInfo: info, onBack: {}))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 310, height: 350),
            styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30))
        window.contentView = nil; window.close()
        model.end(); model.begin()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(flow.working); XCTAssertTrue(connections.isConnecting)
        XCTAssertEqual(model.page, .providers)
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
        if let output = ProcessInfo.processInfo.environment["WHYTAP_CALENDAR_HOVER_RENDER_DIR"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: output), withIntermediateDirectories: true)
            for width: CGFloat in [310, 360, 500] {
                try await render(model, page: .providers, name: "connecting", width: width, info: info,
                    destination: URL(fileURLWithPath: output))
            }
        }
        PlannerURLProtocol.handler = { _ in (200, ["access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600, "token_type": "Bearer"]) }
        pending.continuation.yield((code: "fixture-code", redirect: "http://localhost:8080/callback"))
        pending.continuation.finish()
        for _ in 0..<100 where flow.working { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(flow.working); XCTAssertFalse(connections.isConnecting)
        XCTAssertEqual(completed, 1); XCTAssertEqual(activity, [true, false])
        XCTAssertEqual(connections.accounts.map(\.label), [CalendarProvider.microsoft.title])
        XCTAssertEqual(credentials.saveCount, 1)
        XCTAssertNil(flow.error)
    }

    func testDirectConnectBlocksUnapprovedAndMissingClientsWithoutOpeningAuthorization() async throws {
        let connections = CalendarConnections(defaults: defaults)
        var authorizations = 0
        let flow = CalendarConnectionFlow(connections: connections, authorize: { _, _, _, _ in
            authorizations += 1; throw CalendarConnectionError.denied
        })
        let model = CalendarHoverModel(store: PlannerStore(url: directory.appendingPathComponent("planner.json")),
            connections: connections, connectionFlow: flow)
        for provider in [CalendarProvider.google, .zoom, .microsoft] {
            let info: [String: Any] = ["WhytapCalendarOAuthClients": [provider.rawValue: ["clientID": "fixture"]]]
            XCTAssertFalse(model.connect(provider, info: provider == .microsoft ? [:] : info))
            XCTAssertEqual(model.page, .providers)
            XCTAssertNotNil(flow.error)
            XCTAssertFalse(flow.working); XCTAssertFalse(connections.isConnecting)
        }
        await Task.yield()
        XCTAssertEqual(authorizations, 0); XCTAssertTrue(connections.accounts.isEmpty)
        let approved: [String: Any] = ["WhytapCalendarOAuthClients": ["google": ["clientID": "fixture", "publicAccessApproved": "true"]]]
        XCTAssertTrue(model.connect(.google, info: approved))
        for _ in 0..<100 where flow.working { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(flow.error, CalendarConnectionError.denied.localizedDescription)
        XCTAssertTrue(connections.accounts.isEmpty); XCTAssertFalse(connections.isConnecting)
    }

    func testSettingsDirectConnectionCancelsWhenItsViewCloses() async throws {
        _ = NSApplication.shared
        let connections = CalendarConnections(defaults: defaults)
        let pending = AsyncThrowingStream<(code: String, redirect: String), Error>.makeStream()
        let flow = CalendarConnectionFlow(connections: connections, authorize: { _, _, _, _ in
            var iterator = pending.stream.makeAsyncIterator()
            guard let result = try await iterator.next() else { throw CancellationError() }
            return result
        })
        defer { pending.continuation.finish(); flow.cancel() }
        let info: [String: Any] = ["WhytapCalendarOAuthClients": ["microsoft": ["clientID": "fixture"]]]
        let host = NSHostingView(rootView: SettingsCalendarIntegrationsView(connections: connections,
            readiness: { _ in .available }, configurationInfo: info, flow: flow))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 500, height: 800),
            styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(flow.startRegistered(provider: .microsoft, info: info))
        try await Task.sleep(for: .milliseconds(30))
        let otherFlow = CalendarConnectionFlow(connections: connections)
        XCTAssertFalse(otherFlow.startRegistered(provider: .microsoft, info: info))
        XCTAssertFalse(otherFlow.working)
        XCTAssertTrue(flow.working)
        let unrelated = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        unrelated.isReleasedWhenClosed = false; unrelated.close()
        await Task.yield()
        XCTAssertTrue(flow.working, "Closing another window must not cancel Settings sign-in")
        window.close()
        for _ in 0..<100 where flow.working { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(flow.working); XCTAssertFalse(connections.isConnecting)
        XCTAssertTrue(connections.accounts.isEmpty); XCTAssertNil(flow.error)
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
    }

    func testDirectConnectionsAutomaticallyDistinguishAccountsWithoutAnExtraForm() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlannerURLProtocol.self]
        let http = CalendarHTTP(session: URLSession(configuration: configuration))
        let credentials = PlannerMemoryCredentials()
        let connections = CalendarConnections(defaults: defaults,
            oauth: CalendarOAuthClient(http: http, storage: credentials), http: http)
        let flow = CalendarConnectionFlow(connections: connections, authorize: { _, _, _, _ in
            (code: "fixture-code", redirect: "http://localhost:8080/callback")
        })
        PlannerURLProtocol.handler = { _ in (200, ["access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600, "token_type": "Bearer"]) }
        let info: [String: Any] = ["WhytapCalendarOAuthClients": ["microsoft": ["clientID": "fixture"]]]
        for _ in 0..<2 {
            XCTAssertTrue(flow.startRegistered(provider: .microsoft, info: info))
            for _ in 0..<100 where flow.working { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(flow.working); XCTAssertNil(flow.error)
        }
        XCTAssertEqual(connections.accounts.map(\.label), [CalendarProvider.microsoft.title, "\(CalendarProvider.microsoft.title) · 2"])
        XCTAssertEqual(credentials.saveCount, 2)
        XCTAssertEqual(Set(connections.accounts.map(\.id)).count, 2)
    }

    func testExplicitCancelReleasesConnectionAndSettingsFlowDoesNotBelongToHover() async throws {
        let connections = CalendarConnections(defaults: defaults)
        let pending = AsyncThrowingStream<(code: String, redirect: String), Error>.makeStream()
        let flow = CalendarConnectionFlow(connections: connections, authorize: { _, _, _, _ in
            var iterator = pending.stream.makeAsyncIterator()
            guard let result = try await iterator.next() else { throw CalendarConnectionError.cancelled }
            return result
        })
        defer { pending.continuation.finish(); flow.cancel() }
        let info: [String: Any] = ["WhytapCalendarOAuthClients": ["microsoft": ["clientID": "fixture"]]]
        XCTAssertTrue(flow.start(provider: .microsoft, clientID: "fixture", secret: "", label: "", info: info, onSuccess: { XCTFail("Cancelled") }))
        let otherHover = CalendarHoverModel(store: PlannerStore(url: directory.appendingPathComponent("planner.json")), connections: connections)
        XCTAssertTrue(connections.isConnecting)
        XCTAssertFalse(otherHover.connectionFlow.working, "A Settings operation must not pin Hover's menu")
        flow.cancel()
        for _ in 0..<100 where flow.working { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(flow.working); XCTAssertFalse(connections.isConnecting)
        XCTAssertTrue(connections.accounts.isEmpty); XCTAssertNil(flow.error)
    }

    func testConnectionErrorSurvivesTemporaryHidingAndDoesNotAddAccount() async throws {
        let connections = CalendarConnections(defaults: defaults)
        let flow = CalendarConnectionFlow(connections: connections, authorize: { _, _, _, _ in throw CalendarConnectionError.denied })
        let info: [String: Any] = ["WhytapCalendarOAuthClients": ["microsoft": ["clientID": "fixture"]]]
        XCTAssertTrue(flow.start(provider: .microsoft, clientID: "fixture", secret: "", label: "", info: info, onSuccess: { XCTFail("Denied") }))
        for _ in 0..<100 where flow.working { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(flow.error, CalendarConnectionError.denied.localizedDescription)
        let model = CalendarHoverModel(store: PlannerStore(url: directory.appendingPathComponent("planner.json")),
            connections: connections, connectionFlow: flow)
        model.begin(); model.end(); model.begin()
        XCTAssertNotNil(model.connectionFlow.error)
        XCTAssertFalse(connections.isConnecting); XCTAssertTrue(connections.accounts.isEmpty)
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
            model.connectionFlow.clearError()
            try await render(model, page: .agenda, name: "empty", width: width, info: info, destination: destination)
            try await render(model, page: .providers, name: "providers", width: width, info: info, destination: destination)
            XCTAssertFalse(model.connect(.google, info: info))
            try await render(model, page: .providers, name: "google-pending", width: width, info: info, destination: destination)
            model.connectionFlow.clearError()
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
        try await render(model, page: .providers, name: "busy", width: 310, info: info, destination: destination)
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
