import EventKit
import SwiftUI

@MainActor
final class CalendarConnections: ObservableObject {
    static let shared = CalendarConnections()
    @Published private(set) var accounts: [ConnectedCalendarAccount] = []
    @Published private(set) var feeds: [CalendarFeed] = []
    @Published private(set) var events: [CalendarFeedEvent] = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var lastSynced: [String: Date] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var hiddenFeeds: Set<String> = []
    @Published private(set) var appleEnabled = false
    private let defaults: UserDefaults
    let oauth: CalendarOAuthClient
    private let remote: CalendarRemoteClient
    private var appleStore: EKEventStore?
    private var generation = 0
    private var metadataValid = true
    private static let accountsKey = CalendarAccountSettings.accountsKey

    init(defaults: UserDefaults = .standard, oauth: CalendarOAuthClient = CalendarOAuthClient(),
        http: CalendarHTTP = CalendarHTTP()) {
        self.defaults = defaults; self.oauth = oauth
        remote = CalendarRemoteClient(http: http, oauth: oauth)
        hiddenFeeds = Set(defaults.stringArray(forKey: "planner.calendar.hiddenFeeds") ?? [])
        appleEnabled = defaults.bool(forKey: "planner.calendar.appleEnabled")
        if let data = defaults.data(forKey: Self.accountsKey) {
            do {
                accounts = try CalendarAccountSettings.decode(data)
            }
            catch { metadataValid = false; errors["accounts"] = "Couldn’t read your calendar connections. Saved settings have been kept." }
        }
    }

    func add(_ account: ConnectedCalendarAccount) throws {
        guard metadataValid, accounts.count < 64, account.provider != .apple, !accounts.contains(where: { $0.id == account.id }),
              !account.label.isEmpty, account.label.count <= 120 else { throw CalendarConnectionError.configuration }
        let candidate = accounts + [account]
        defaults.set(try JSONEncoder().encode(candidate), forKey: Self.accountsKey)
        accounts = candidate
    }

    func remove(_ account: ConnectedCalendarAccount) async throws {
        try await oauth.disconnect(account.id)
        let candidate = accounts.filter { $0.id != account.id }
        defaults.set(try JSONEncoder().encode(candidate), forKey: Self.accountsKey)
        accounts = candidate
        generation += 1
        refreshing = false
        let ids = Set(feeds.filter { $0.accountID == account.id }.map(\.id))
        feeds.removeAll { ids.contains($0.id) }; events.removeAll { ids.contains($0.feedID) }
        errors.removeValue(forKey: account.id.uuidString); lastSynced.removeValue(forKey: account.id.uuidString)
    }

    func setVisible(_ visible: Bool, feedID: String) {
        if visible { hiddenFeeds.remove(feedID) } else { hiddenFeeds.insert(feedID) }
        defaults.set(Array(hiddenFeeds), forKey: "planner.calendar.hiddenFeeds")
    }

    func enableApple() async throws {
        let store = appleStore ?? EKEventStore()
        appleStore = store
        guard try await store.requestFullAccessToEvents() else { throw CalendarConnectionError.denied }
        appleEnabled = true
        defaults.set(true, forKey: "planner.calendar.appleEnabled")
    }

    func disableApple() {
        generation += 1
        refreshing = false
        appleEnabled = false
        defaults.set(false, forKey: "planner.calendar.appleEnabled")
        feeds.removeAll { $0.provider == .apple }
        events.removeAll { $0.feedID.hasPrefix("apple:") }
        errors.removeValue(forKey: "apple"); lastSynced.removeValue(forKey: "apple")
    }

    func refresh(interval: DateInterval) async {
        generation += 1
        let current = generation
        refreshing = true
        defer { if generation == current { refreshing = false } }
        if appleEnabled {
            do { try refreshApple(interval: interval); errors.removeValue(forKey: "apple"); lastSynced["apple"] = Date() }
            catch { errors["apple"] = error.localizedDescription }
        }
        for account in accounts {
            guard !Task.isCancelled, generation == current else { return }
            let key = account.id.uuidString
            do {
                let snapshot = try await remote.snapshot(account: account, interval: interval)
                guard !Task.isCancelled, generation == current, accounts.contains(where: { $0.id == account.id }) else { return }
                let previous = Set(feeds.filter { $0.accountID == account.id }.map(\.id))
                feeds.removeAll { previous.contains($0.id) }
                events.removeAll { previous.contains($0.feedID) }
                feeds += snapshot.feeds; events += snapshot.events
                lastSynced[key] = Date(); errors.removeValue(forKey: key)
            } catch is CancellationError { return }
            catch { if generation == current { errors[key] = error.localizedDescription } }
        }
    }

    private func refreshApple(interval: DateInterval) throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            feeds.removeAll { $0.provider == .apple }; events.removeAll { $0.feedID.hasPrefix("apple:") }
            throw CalendarConnectionError.denied
        }
        let store = appleStore ?? EKEventStore()
        appleStore = store
        let calendars = store.calendars(for: .event)
        let foundFeeds = calendars.map { calendar in
            CalendarFeed(id: "apple:" + calendar.calendarIdentifier, accountID: nil, remoteID: calendar.calendarIdentifier,
                title: calendar.title + " · " + calendar.source.title, provider: .apple)
        }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        let foundEvents = store.events(matching: predicate).map { event in
            CalendarFeedEvent(id: "apple:" + (event.eventIdentifier ?? event.calendarItemIdentifier) + ":" + CalendarDateCodec.string(event.startDate),
                feedID: "apple:" + event.calendar.calendarIdentifier,
                event: PlannerEvent(title: event.title ?? "Untitled event", start: event.startDate, end: event.endDate,
                    allDay: event.isAllDay, location: event.location ?? "", notes: event.notes ?? "",
                    meetingURL: CalendarDateCodec.meetingURL(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " "))),
                sourceURL: nil, externalUID: event.calendarItemExternalIdentifier)
        }
        feeds.removeAll { $0.provider == .apple }; events.removeAll { $0.feedID.hasPrefix("apple:") }
        feeds += foundFeeds; events += foundEvents
    }
}
