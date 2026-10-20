import Foundation

struct PlannerTask: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var completed = false
    var createdAt = Date()
    // Optional for archives saved before completion history was introduced.
    var completedAt: Date?
}

struct PlannerEvent: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var allDay = false
    var location = ""
    var notes = ""
    var meetingURL: URL?
    var timeZoneIdentifier = TimeZone.current.identifier

    func displayBounds(calendar: Calendar = .current) -> DateInterval {
        guard allDay, let zone = TimeZone(identifier: timeZoneIdentifier) else { return DateInterval(start: start, end: end) }
        var original = calendar
        original.timeZone = zone
        let startDay = calendar.date(from: original.dateComponents([.year, .month, .day], from: start)) ?? start
        // Accept both exclusive midnight and an inclusive final-day time from
        // calendar adapters, without dropping the final civil day.
        let originalEndDay = original.startOfDay(for: end)
        let exclusiveEnd = end == originalEndDay ? end :
            (original.date(byAdding: .day, value: 1, to: originalEndDay) ?? end)
        let endDay = calendar.date(from: original.dateComponents([.year, .month, .day], from: exclusiveEnd)) ?? end
        return DateInterval(start: startDay, end: max(startDay, endDay))
    }

    func occurs(on day: Date, calendar: Calendar = .current) -> Bool {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return false }
        let bounds = displayBounds(calendar: calendar)
        return bounds.start < interval.end && bounds.end > interval.start
    }

    mutating func moveStart(to date: Date, calendar: Calendar = .current) {
        if allDay {
            let days = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: end).day ?? 1)
            start = calendar.startOfDay(for: date)
            end = calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(86400)
        } else {
            let duration = max(1, end.timeIntervalSince(start))
            start = date
            end = date.addingTimeInterval(duration)
        }
    }

    /// Keep the selected civil dates while restoring the previous time of day.
    mutating func convertAllDay(_ enabled: Bool, timedRange: inout DateInterval?, calendar: Calendar = .current) {
        allDay = enabled
        if enabled {
            if end > start { timedRange = DateInterval(start: start, end: end) }
            let endDay = calendar.startOfDay(for: end)
            start = calendar.startOfDay(for: start)
            end = end == endDay && end > start ? endDay :
                (calendar.date(byAdding: .day, value: 1, to: max(start, endDay)) ?? start.addingTimeInterval(86400))
            timeZoneIdentifier = calendar.timeZone.identifier
        } else {
            let startTime = timedRange.map { calendar.dateComponents([.hour, .minute, .second], from: $0.start) }
                ?? DateComponents(hour: 10, minute: 0, second: 0)
            let endTime = timedRange.map { calendar.dateComponents([.hour, .minute, .second], from: $0.end) }
                ?? DateComponents(hour: 11, minute: 0, second: 0)
            let midnightEnd = endTime.hour == 0 && endTime.minute == 0 && endTime.second == 0
            let lastDay = midnightEnd ? end : (calendar.date(byAdding: .day, value: -1, to: end) ?? start)
            start = calendar.date(bySettingHour: startTime.hour ?? 10, minute: startTime.minute ?? 0,
                second: startTime.second ?? 0, of: start) ?? start
            end = calendar.date(bySettingHour: endTime.hour ?? 11, minute: endTime.minute ?? 0,
                second: endTime.second ?? 0, of: lastDay) ?? end
            if end <= start { end = start.addingTimeInterval(3600) }
        }
    }
}

/// Private local data. Failed loads block writes; failed writes never change the visible data.
@MainActor
final class PlannerStore: ObservableObject {
    static let shared = PlannerStore(url: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("Sidekey/Planner/planner-v1.json"))

    struct Archive: Codable, Equatable, Sendable {
        var version = 1
        var tasks: [PlannerTask] = []
        var events: [PlannerEvent] = []
    }

    @Published private(set) var archive = Archive()
    @Published private(set) var errorMessage: String?
    @Published private(set) var canWrite = false
    private let url: URL
    private let write: (Data, URL) throws -> Void

    init(url: URL, write: @escaping (Data, URL) throws -> Void = { data, url in
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        // The containing directory is private; a metadata failure after atomic save must not report lost data.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }) {
        self.url = url
        self.write = write
        reload()
    }

    func reload() {
        do {
            let loaded: Archive
            do {
                loaded = try Self.decodeArchive(Data(contentsOf: url, options: .mappedIfSafe))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                loaded = Archive()
            }
            archive = loaded
            canWrite = true
            errorMessage = nil
        } catch {
            canWrite = false
            errorMessage = "Couldn’t read your planner. Your saved file has been kept. Restore access or a backup, then retry."
        }
    }

    @discardableResult
    func saveTask(_ task: PlannerTask, now: Date = Date()) -> Bool {
        var task = task
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = archive.tasks.first { $0.id == task.id }
        if !task.completed { task.completedAt = nil }
        else if previous?.completed == false || previous == nil { task.completedAt = now }
        else { task.completedAt = previous?.completedAt }
        guard Self.validationMessage(for: task) == nil else { return false }
        return commit { value in
            if let index = value.tasks.firstIndex(where: { $0.id == task.id }) { value.tasks[index] = task }
            else { value.tasks.append(task) }
        }
    }

    @discardableResult
    func deleteTask(_ id: UUID) -> Bool { commit { $0.tasks.removeAll { $0.id == id } } }

    @discardableResult
    func saveEvent(_ event: PlannerEvent) -> Bool {
        var event = event
        event.title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validationMessage(for: event) == nil else { return false }
        return commit { value in
            if let index = value.events.firstIndex(where: { $0.id == event.id }) { value.events[index] = event }
            else { value.events.append(event) }
        }
    }

    @discardableResult
    func deleteEvent(_ id: UUID) -> Bool { commit { $0.events.removeAll { $0.id == id } } }

    private func commit(_ change: (inout Archive) -> Void) -> Bool {
        guard canWrite else { return false }
        var candidate = archive
        change(&candidate)
        do {
            let data = try JSONEncoder().encode(candidate)
            _ = try Self.decodeArchive(data)
            try write(data, url)
            archive = candidate
            errorMessage = nil
            NotificationCenter.default.post(name: .exodiaBackupArtifactsChanged, object: nil)
            return true
        } catch {
            errorMessage = "Couldn’t save your changes. Check available storage and folder access, then try again."
            return false
        }
    }

    nonisolated static func decodeArchive(_ data: Data) throws -> Archive {
        guard data.count <= 8 * 1024 * 1024 else { throw StoreError.invalid }
        let loaded = try JSONDecoder().decode(Archive.self, from: data)
        guard loaded.version == 1, loaded.tasks.count <= 10_000, loaded.events.count <= 10_000,
              Set(loaded.tasks.map(\.id)).count == loaded.tasks.count,
              Set(loaded.events.map(\.id)).count == loaded.events.count,
              loaded.tasks.allSatisfy({ validTitle($0.title) && $0.createdAt.timeIntervalSince1970.isFinite && ($0.completedAt?.timeIntervalSince1970.isFinite ?? true) }),
              loaded.events.allSatisfy(validEvent) else { throw StoreError.invalid }
        return loaded
    }

    nonisolated private static func validTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 500
    }

    nonisolated private static func validEvent(_ event: PlannerEvent) -> Bool {
        validationMessage(for: event) == nil
    }

    nonisolated static func validationMessage(for task: PlannerTask) -> String? {
        validTitle(task.title) ? nil : "Enter a task between 1 and 500 characters."
    }

    nonisolated static func validationMessage(for event: PlannerEvent) -> String? {
        guard validTitle(event.title) else { return "Enter an event title between 1 and 500 characters." }
        guard event.start.timeIntervalSince1970.isFinite, event.end.timeIntervalSince1970.isFinite,
              event.end > event.start else { return "Choose an end time after the start." }
        guard event.location.count <= 2000 else { return "Keep the location within 2,000 characters." }
        guard event.notes.count <= 20_000 else { return "Keep notes within 20,000 characters." }
        guard event.meetingURL == nil || CalendarDateCodec.safeURL(event.meetingURL?.absoluteString) != nil else {
            return "Enter a valid https meeting link."
        }
        return nil
    }

    private enum StoreError: Error { case invalid }
}
