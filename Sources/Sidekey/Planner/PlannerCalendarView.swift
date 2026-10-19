import AppKit
import EventKit
import SwiftUI

enum PlannerMonth {
    static func days(containing date: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return [] }
        let offset = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        guard let first = calendar.date(byAdding: .day, value: -offset, to: month.start) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    static func counts(events: [CalendarFeedEvent], days: [Date], calendar: Calendar = .current) -> [Date: Int] {
        let intervals = days.compactMap { calendar.dateInterval(of: .day, for: $0) }
        var result: [Date: Int] = [:]
        for event in events {
            let bounds = event.event.displayBounds(calendar: calendar)
            for day in intervals where bounds.start < day.end && bounds.end > day.start { result[day.start, default: 0] += 1 }
        }
        return result
    }
}

struct PlannerCalendarView: View {
    @ObservedObject var store: PlannerStore
    @ObservedObject var navigation: PlannerNavigation
    @ObservedObject var connections: CalendarConnections = .shared
    @State private var editing: PlannerEvent?
    @State private var deleting: PlannerEvent?
    @State private var selectedRemote: CalendarFeedEvent?
    @State private var showCalendars = false
    @State private var showConnect = false
    @State private var refreshToken = 0
    private var calendar: Calendar { .current }
    private var days: [Date] { PlannerMonth.days(containing: navigation.selectedDay) }
    private var visibleEvents: [CalendarFeedEvent] {
        let local = connections.hiddenFeeds.contains("local") ? [] : store.archive.events.map {
            CalendarFeedEvent(id: $0.id.uuidString, feedID: "local", event: $0, sourceURL: nil)
        }
        return CalendarEventMerger.merge(local + connections.events.filter { !connections.hiddenFeeds.contains($0.feedID) })
    }
    private var selectedEvents: [CalendarFeedEvent] {
        visibleEvents.filter { $0.event.occurs(on: navigation.selectedDay) }.sorted {
            if $0.event.allDay != $1.event.allDay { return $0.event.allDay }
            return $0.event.start < $1.event.start
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack {
                Button { showCalendars.toggle() } label: { Label("Calendars", systemImage: "line.3.horizontal.decrease.circle") }
                    .popover(isPresented: $showCalendars) {
                        CalendarSourcesView(connections: connections, onConnect: { showCalendars = false; showConnect = true })
                    }
                Button { showConnect = true } label: { Label("Connect account", systemImage: "plus") }
                Spacer()
                if connections.refreshing { ProgressView().controlSize(.small) }
                Button { refreshToken += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh calendars").accessibilityLabel("Refresh calendars")
            }
            if !connections.errors.isEmpty {
                Label("Some calendars need attention. Open Calendars for details; previously loaded events may be out of date.",
                    systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            monthGrid
            Divider()
            HStack {
                Text(navigation.selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.headline)
                Spacer()
                Text(TimeZone.current.identifier).font(.caption).foregroundStyle(.secondary)
            }
            if selectedEvents.isEmpty {
                PlannerEmptyState(symbol: "calendar", title: "Your day is open",
                    subtitle: connections.accounts.isEmpty && !connections.appleEnabled ?
                        "Add an event or connect a calendar to see your schedule." : "No events in your selected calendars.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(selectedEvents) { item in eventRow(item) }
                    }
                }
            }
        }
        .padding(24)
        .sheet(item: $editing) { PlannerEventEditor(event: $0, store: store) }
        .sheet(item: $selectedRemote) { item in
            CalendarEventDetails(item: item, source: sourceTitle(item.feedID))
        }
        .sheet(isPresented: $showConnect) { CalendarConnectView(connections: connections) }
        .alert("Delete this event?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let event = deleting { _ = store.deleteEvent(event.id) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This removes the event from your local Whytap calendar.") }
        .task(id: "\(days.first?.timeIntervalSince1970 ?? 0):\(refreshToken)") {
            guard let first = days.first, let end = calendar.date(byAdding: .day, value: 42, to: first) else { return }
            repeat {
                await connections.refresh(interval: DateInterval(start: first, end: end))
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            } while !Task.isCancelled
        }
        .onChange(of: connections.accounts) { _, _ in refreshToken += 1 }
        .onChange(of: connections.appleEnabled) { _, _ in refreshToken += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in refreshToken += 1 }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Calendar").font(.largeTitle.bold())
                HStack(spacing: 12) {
                    Text(navigation.selectedDay.formatted(.dateTime.month(.wide).year())).font(.title3.weight(.medium))
                    Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous month")
                    Button { navigation.selectedDay = Date() } label: { Text("Today") }
                    Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next month")
                }.buttonStyle(.borderless)
            }
            Spacer()
            Button { editing = newEvent() } label: { Label("New event", systemImage: "plus") }
                .buttonStyle(.borderedProminent).disabled(!store.canWrite)
        }
    }

    private var monthGrid: some View {
        let counts = PlannerMonth.counts(events: visibleEvents, days: days)
        return VStack(spacing: 5) {
            HStack(spacing: 4) {
                ForEach(0..<7) { index in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[(index + calendar.firstWeekday - 1) % 7])
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { day in
                    let selected = calendar.isDate(day, inSameDayAs: navigation.selectedDay)
                    let count = counts[day, default: 0]
                    Button { navigation.selectedDay = day } label: {
                        VStack(spacing: 3) {
                            Text("\(calendar.component(.day, from: day))")
                                .font(.system(size: 13, weight: calendar.isDateInToday(day) ? .bold : .regular))
                            Text(count > 0 ? "\(count)" : " ").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(selected ? .white.opacity(0.8) : Color.accentColor)
                        }
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .foregroundStyle(selected ? .white : .primary)
                        .opacity(calendar.isDate(day, equalTo: navigation.selectedDay, toGranularity: .month) ? 1 : 0.4)
                        .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                    .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(count) events")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func eventRow(_ item: CalendarFeedEvent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 2).fill(item.feedID == "local" ? Color.accentColor : .purple).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.event.allDay ? "All day" : item.event.start.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Button { if item.feedID == "local" { editing = item.event } else { selectedRemote = item } } label: {
                    Text(item.event.title).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                }.buttonStyle(.plain)
                Text(sourceTitle(item.feedID) + (item.additionalFeedIDs.isEmpty ? "" : " (+\(item.additionalFeedIDs.count))"))
                    .font(.caption).foregroundStyle(.secondary)
                if !item.event.location.isEmpty { Text(item.event.location).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            if let url = item.event.meetingURL { Link("Join", destination: url).buttonStyle(.borderedProminent) }
            if item.feedID == "local" {
                Button { editing = item.event } label: { Image(systemName: "pencil") }
                    .help("Edit event").accessibilityLabel("Edit event: \(item.event.title)")
                Button { deleting = item.event } label: { Image(systemName: "trash") }
                    .help("Delete event").accessibilityLabel("Delete event: \(item.event.title)")
            }
        }
        .padding(13).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sourceTitle(_ id: String) -> String {
        if id == "local" { return "Whytap · On this Mac" }
        guard let feed = connections.feeds.first(where: { $0.id == id }) else { return "Connected calendar" }
        return feed.title + " · " + (feed.provider?.title ?? "")
    }
    private func moveMonth(_ offset: Int) {
        if let day = calendar.date(byAdding: .month, value: offset, to: navigation.selectedDay) { navigation.selectedDay = day }
    }
    private func newEvent() -> PlannerEvent {
        let start = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: navigation.selectedDay) ?? navigation.selectedDay
        return PlannerEvent(title: "", start: start, end: start.addingTimeInterval(3600))
    }
}

struct PlannerEventEditor: View {
    @State var event: PlannerEvent
    @ObservedObject var store: PlannerStore
    @State private var meetingLink = ""
    @State private var validationMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(event: PlannerEvent, store: PlannerStore) {
        var editable = event
        if editable.allDay {
            let bounds = editable.displayBounds()
            editable.start = bounds.start; editable.end = bounds.end
            editable.timeZoneIdentifier = TimeZone.current.identifier
        }
        _event = State(initialValue: editable)
        self.store = store
    }

    private var lastDay: Binding<Date> {
        Binding(get: { Calendar.current.date(byAdding: .day, value: -1, to: event.end) ?? event.start },
            set: { event.end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: $0)) ?? $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Whytap event").font(.title2.bold())
            TextField("Event title", text: $event.title).textFieldStyle(.roundedBorder).accessibilityLabel("Event title")
            Form {
                Toggle("All day", isOn: $event.allDay)
                DatePicker("Start", selection: $event.start, displayedComponents: event.allDay ? [.date] : [.date, .hourAndMinute])
                if event.allDay { DatePicker("Last day", selection: lastDay, displayedComponents: [.date]) }
                else { DatePicker("End", selection: $event.end, displayedComponents: [.date, .hourAndMinute]) }
                TextField("Location", text: $event.location)
                TextField("Meeting link (https)", text: $meetingLink)
            }
            Text("Notes").font(.callout.weight(.medium))
            TextEditor(text: $event.notes).frame(height: 85).border(Color.secondary.opacity(0.2))
            Text("Saved in Whytap on this Mac. Connected calendars are shown alongside it; they are read-only.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = validationMessage ?? store.errorMessage { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canWrite)
            }
        }.padding(24).frame(width: 490).background(Color(nsColor: .windowBackgroundColor))
        .onAppear { meetingLink = event.meetingURL?.absoluteString ?? "" }
        .onChange(of: event.allDay) { _, allDay in
            if allDay {
                event.timeZoneIdentifier = TimeZone.current.identifier
                event.start = Calendar.current.startOfDay(for: event.start)
                event.end = Calendar.current.date(byAdding: .day, value: 1, to: event.start) ?? event.start.addingTimeInterval(86400)
            }
        }
    }

    private func save() {
        let link = meetingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.isEmpty || CalendarDateCodec.safeURL(link) != nil else { validationMessage = "Enter a valid https meeting link."; return }
        event.meetingURL = CalendarDateCodec.safeURL(link)
        if event.allDay { event.start = Calendar.current.startOfDay(for: event.start); event.end = Calendar.current.startOfDay(for: event.end) }
        if store.saveEvent(event) { dismiss() }
    }
}

private struct CalendarEventDetails: View {
    let item: CalendarFeedEvent
    let source: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(item.event.title).font(.title2.bold()).textSelection(.enabled)
            Text(source).foregroundStyle(.secondary)
            Text(item.event.displayBounds().start.formatted(date: .complete, time: item.event.allDay ? .omitted : .shortened))
            if !item.event.allDay { Text("Until " + item.event.end.formatted(date: .abbreviated, time: .shortened)) }
            if !item.event.location.isEmpty { Label(item.event.location, systemImage: "location") }
            if !item.event.notes.isEmpty { ScrollView { Text(item.event.notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 200) }
            Text("This connected event is read-only in Whytap.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if let url = item.event.meetingURL { Link("Join meeting", destination: url).buttonStyle(.borderedProminent) }
                if let url = item.sourceURL { Link("Open original", destination: url) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 500)
    }
}
