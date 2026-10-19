import Foundation

/// Queue of Case Approve prompts shown in the island, one at a time (FIFO).
///
/// Each prompt ignores keys and clicks for `armingDelay` after it appears, so a
/// person typing in another app cannot answer it by accident, and is denied as
/// `.timedOut` after `timeout`. The key tap exists only while the queue is non-empty;
/// without it (no Accessibility) the prompt is answered by click.
@MainActor
final class CaseApprovalController: ObservableObject, CaseApprovalPresenting {
    static let armingDelay: TimeInterval = 0.3
    static let timeout: TimeInterval = 60

    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    /// The prompt on screen.
    @Published private(set) var current: CaseApprovalRequest?
    /// Whether the visible prompt accepts answers yet.
    @Published private(set) var isArmed = false
    /// Prompts waiting behind the visible one.
    @Published private(set) var pendingCount = 0
    /// When the visible prompt is denied without an answer.
    @Published private(set) var deadline: Date?
    /// False when the key tap could not be installed; the prompt then works by click.
    @Published private(set) var keysAvailable = true
    /// Changes with every prompt shown, so the view starts each one fresh.
    @Published private(set) var promptSerial = 0

    private struct Entry {
        let request: CaseApprovalRequest
        let continuation: CheckedContinuation<CaseApprovalOutcome, Never>
    }

    private let keyTap: CaseApprovalKeyIntercepting
    private let now: () -> Date
    private let schedule: Schedule
    private var active: Entry?
    private var queue: [Entry] = []
    private var cancelTimers: [() -> Void] = []
    private var tapRunning = false

    init(keyTap: CaseApprovalKeyIntercepting? = nil,
         now: @escaping () -> Date = Date.init,
         schedule: Schedule? = nil) {
        self.keyTap = keyTap ?? CaseApprovalKeyTap()
        self.now = now
        self.schedule = schedule ?? { delay, work in
            let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        }
    }

    /// Visible plus waiting prompts.
    var queuedCount: Int { (active == nil ? 0 : 1) + queue.count }

    /// The «На N мин» answer exists only for a positive N.
    var offersTimed: Bool { (current?.timedMinutes ?? 0) > 0 }

    func requestApproval(_ r: CaseApprovalRequest) async -> CaseApprovalOutcome {
        await withCheckedContinuation { continuation in
            queue.append(Entry(request: r, continuation: continuation))
            if active == nil {
                showNext()
            } else {
                pendingCount = queue.count
            }
        }
    }

    /// A click on one of the prompt's buttons. Ignored until the prompt is armed.
    func choose(_ outcome: CaseApprovalOutcome) {
        guard acceptsAnswer else { return }
        if outcome == .allowTimed, !offersTimed { return }
        resolve(outcome)
    }

    /// Answers the visible prompt and shows the next one.
    func resolve(_ outcome: CaseApprovalOutcome) {
        guard let entry = active else { return }
        clearTimers()
        active = nil
        entry.continuation.resume(returning: outcome)
        if queue.isEmpty {
            current = nil
            isArmed = false
            deadline = nil
            pendingCount = 0
            stopTap()
        } else {
            showNext()
        }
    }

    /// Denies every prompt, visible and waiting (app quit).
    func cancelAll() {
        let waiting = queue
        queue.removeAll()
        resolve(.deny)
        for entry in waiting { entry.continuation.resume(returning: .deny) }
    }

    // MARK: - Private

    /// Armed only by the arming timer, which cannot fire before `armingDelay` has passed.
    private var acceptsAnswer: Bool { active != nil && isArmed }

    private func handleKey(_ key: CaseApprovalKey) {
        switch key {
        case .yes: choose(.allow)
        case .no, .escape: choose(.deny)
        case .timed: choose(.allowTimed)
        }
    }

    private func showNext() {
        guard !queue.isEmpty else { return }
        let entry = queue.removeFirst()
        active = entry
        let shown = now()
        isArmed = false
        pendingCount = queue.count
        deadline = shown.addingTimeInterval(Self.timeout)
        promptSerial += 1
        current = entry.request
        startTapIfNeeded()
        keyTap.setArmed(false)
        // Timers carry their prompt's serial, so a late one never touches the next prompt.
        let serial = promptSerial
        cancelTimers = [
            schedule(Self.armingDelay) { [weak self] in
                guard let self, self.active != nil, self.promptSerial == serial else { return }
                self.isArmed = true
                self.keyTap.setArmed(true)
            },
            schedule(Self.timeout) { [weak self] in
                guard let self, self.promptSerial == serial else { return }
                self.resolve(.timedOut)
            },
        ]
    }

    private func startTapIfNeeded() {
        guard !tapRunning else { return }
        do {
            try keyTap.start { [weak self] key in self?.handleKey(key) }
            tapRunning = true
            keysAvailable = true
        } catch {
            keysAvailable = false
        }
    }

    private func stopTap() {
        keyTap.setArmed(false)
        guard tapRunning else { return }
        keyTap.stop()
        tapRunning = false
    }

    private func clearTimers() {
        cancelTimers.forEach { $0() }
        cancelTimers = []
    }
}
