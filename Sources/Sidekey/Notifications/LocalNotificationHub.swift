import Combine
import Foundation

actor NotifyArchive {
    private let url: URL
    private var events: [LocalNotificationEvent]?
    private var revision = 0
    init(url: URL) { self.url = url }

    func load() throws -> (Int, [LocalNotificationEvent]) {
        if events == nil {
            if FileManager.default.fileExists(atPath: url.path) {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 8 * 1024 * 1024 else { throw NotifyError.historyUnavailable }
                events = Array(try JSONDecoder().decode([LocalNotificationEvent].self, from: Data(contentsOf: url)).prefix(500))
            } else { events = [] }
        }
        return (revision, events!)
    }

    func insert(_ event: LocalNotificationEvent) throws -> (Int, [LocalNotificationEvent])? {
        var next = try load().1
        guard !next.contains(where: { $0.id == event.id }) else { return nil }
        next.insert(event, at: 0)
        return try save(Array(next.prefix(500)))
    }
    func markRead() throws -> (Int, [LocalNotificationEvent]) {
        try save(load().1.map { var item = $0; item.read = true; return item })
    }
    func clear() throws -> (Int, [LocalNotificationEvent]) {
        _ = try load() // Never overwrite an unreadable existing history.
        return try save([])
    }
    private func save(_ next: [LocalNotificationEvent]) throws -> (Int, [LocalNotificationEvent]) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        events = next; revision += 1
        return (revision, next)
    }
}

/// One queue and durable presentation metadata shared by the pill and Notify history.
@MainActor
final class LocalNotificationHub: ObservableObject {
    static let shared = LocalNotificationHub(directory: NotifyPaths.root)
    @Published private(set) var history: [LocalNotificationEvent] = []
    @Published private(set) var current: LocalNotificationEvent?
    @Published private(set) var deadline: Date?
    @Published private(set) var error: String?
    var unreadCount: Int { history.filter { !$0.read }.count }
    private let archive: NotifyArchive
    private var historyRevision = -1
    private var queue: [LocalNotificationEvent] = []
    private var dismissTask: Task<Void, Never>?
    private var remaining: TimeInterval?
    private var suspended = false

    init(directory: URL) { archive = NotifyArchive(url: directory.appendingPathComponent("history.json")) }
    func load() async {
        do { updateHistory(try await archive.load()) }
        catch { self.error = "Couldn’t read notification history. Its file has been preserved." }
    }
    @discardableResult
    func receive(_ event: LocalNotificationEvent) async -> Bool {
        do {
            guard let snapshot = try await archive.insert(event) else { return false }
            updateHistory(snapshot)
            if !suspended && queue.count < 32 { queue.append(event); if current == nil { advance() } }
            return true
        } catch { self.error = "Couldn’t save notification history."; return false }
    }
    func markRead() async {
        do { updateHistory(try await archive.markRead()) }
        catch { self.error = "Couldn’t update notification history." }
    }
    func clear() async {
        do { updateHistory(try await archive.clear()); queue.removeAll(); dismiss() }
        catch { self.error = "Couldn’t clear notification history." }
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        if value { queue.removeAll(); dismiss() }
    }
    func dismiss() { advance() }
    func setHovered(_ hovered: Bool) {
        guard current != nil else { return }
        if hovered, remaining == nil {
            remaining = max(0, deadline?.timeIntervalSinceNow ?? 0)
            dismissTask?.cancel()
        } else if !hovered, let seconds = remaining {
            remaining = nil; schedule(after: seconds)
        }
    }
    private func updateHistory(_ snapshot: (Int, [LocalNotificationEvent])) {
        guard snapshot.0 >= historyRevision else { return }
        historyRevision = snapshot.0; history = snapshot.1; error = nil
    }
    private func advance() {
        dismissTask?.cancel(); remaining = nil
        if queue.isEmpty { current = nil; deadline = nil; return }
        let event = queue.removeFirst()
        deadline = Date().addingTimeInterval(event.customDuration ?? 8)
        current = event
        schedule(after: event.customDuration ?? 8)
    }
    private func schedule(after seconds: TimeInterval) {
        deadline = Date().addingTimeInterval(seconds)
        let id = current?.id
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
            catch { return }
            guard let self, self.current?.id == id else { return }
            self.advance()
        }
    }
}
