import Foundation

struct PlannerTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var completed = false
    var createdAt = Date()
}

struct PlannerEvent: Codable, Identifiable, Equatable {
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
        let endDay = calendar.date(from: original.dateComponents([.year, .month, .day], from: end)) ?? end
        return DateInterval(start: startDay, end: max(startDay, endDay))
    }

    func occurs(on day: Date, calendar: Calendar = .current) -> Bool {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return false }
        let bounds = displayBounds(calendar: calendar)
        return bounds.start < interval.end && bounds.end > interval.start
    }
}

/// Private local data. Failed loads block writes; failed writes never change the visible data.
@MainActor
final class PlannerStore: ObservableObject {
    static let shared = PlannerStore(url: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("Sidekey/Planner/planner-v1.json"))

    struct Archive: Codable, Equatable {
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
                loaded = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                loaded = Archive()
            }
            guard loaded.version == 1,
                  Set(loaded.tasks.map(\.id)).count == loaded.tasks.count,
                  Set(loaded.events.map(\.id)).count == loaded.events.count,
                  loaded.tasks.allSatisfy({ Self.validTitle($0.title) }),
                  loaded.events.allSatisfy(Self.validEvent) else { throw StoreError.invalid }
            archive = loaded
            canWrite = true
            errorMessage = nil
        } catch {
            canWrite = false
            errorMessage = "Couldn’t read your planner. Your saved file has been kept. Restore access or a backup, then retry."
        }
    }

    @discardableResult
    func saveTask(_ task: PlannerTask) -> Bool {
        var task = task
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validTitle(task.title) else {
            errorMessage = "Enter a task between 1 and 500 characters."
            return false
        }
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
        guard Self.validEvent(event) else {
            errorMessage = "Enter a title and an end time after the start. Meeting links must use https."
            return false
        }
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
            try write(JSONEncoder().encode(candidate), url)
            archive = candidate
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn’t save your changes. Check available storage and folder access, then try again."
            return false
        }
    }

    private static func validTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 500
    }

    private static func validEvent(_ event: PlannerEvent) -> Bool {
        validTitle(event.title) && event.start.timeIntervalSince1970.isFinite &&
        event.end.timeIntervalSince1970.isFinite && event.end > event.start &&
        event.location.count <= 2000 && event.notes.count <= 20_000 &&
        (event.meetingURL == nil || CalendarDateCodec.safeURL(event.meetingURL?.absoluteString) != nil)
    }

    private enum StoreError: Error { case invalid }
}
