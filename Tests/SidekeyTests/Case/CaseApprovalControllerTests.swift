import Carbon.HIToolbox
import Combine
import SwiftUI
import CoreGraphics
import XCTest
@testable import Sidekey

// Requests carry obviously fake names; no real secrets or commands.

@MainActor
private final class FakeApprovalKeyTap: CaseApprovalKeyIntercepting {
    var failsToStart = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var armedHistory: [Bool] = []
    private var onKey: (@MainActor (CaseApprovalKey) -> Void)?

    var isRunning: Bool { onKey != nil }
    var isArmed: Bool { armedHistory.last ?? false }

    func start(onKey: @escaping @MainActor (CaseApprovalKey) -> Void) throws {
        startCount += 1
        if failsToStart { throw CaseApprovalKeyTapError.unavailable }
        self.onKey = onKey
    }

    func stop() {
        stopCount += 1
        onKey = nil
    }

    func setArmed(_ armed: Bool) { armedHistory.append(armed) }

    /// A physical key press the real tap would deliver (only while running).
    func press(_ key: CaseApprovalKey) { onKey?(key) }
}

/// Manual clock: scheduled work fires only when the test advances time.
@MainActor
private final class FakeApprovalClock {
    private(set) var now = Date(timeIntervalSinceReferenceDate: 1_000)
    private var nextID = 0
    private var items: [(id: Int, at: Date, work: @MainActor () -> Void)] = []

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        items.append((id, now.addingTimeInterval(delay), work))
        return { [weak self] in self?.items.removeAll { $0.id == id } }
    }

    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let next = items.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
            items.removeAll { $0.id == next.id }
            now = next.at
            next.work()
        }
        now = target
    }
}

@MainActor
final class CaseApprovalControllerTests: XCTestCase {
    private var tap: FakeApprovalKeyTap!
    private var clock: FakeApprovalClock!
    private var controller: CaseApprovalController!

    override func setUp() async throws {
        tap = FakeApprovalKeyTap()
        clock = FakeApprovalClock()
        let clock = clock!
        controller = CaseApprovalController(
            keyTap: tap,
            now: { clock.now },
            schedule: { delay, work in clock.schedule(after: delay, work) })
    }

    private func request(_ app: String = "Claude Code", project: String = "alpha",
                         keys: [String] = ["API_TOKEN"], command: String = "npm run deploy",
                         minutes: Int = 15) -> CaseApprovalRequest {
        CaseApprovalRequest(appName: app, projectName: project, keyNames: keys,
                            command: command, timedMinutes: minutes)
    }

    /// Starts an approval the way the broker does and waits until it is queued.
    private func ask(_ r: CaseApprovalRequest) async -> Task<CaseApprovalOutcome, Never> {
        let before = controller.queuedCount
        let task = Task { await self.controller.requestApproval(r) }
        for _ in 0..<200 where controller.queuedCount == before { await Task.yield() }
        XCTAssertEqual(controller.queuedCount, before + 1, "request was not queued")
        return task
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - Brief tests

    func test_keys_ignored_during_first_300ms() async {
        let task = await ask(request())
        XCTAssertEqual(controller.current, request())
        XCTAssertFalse(controller.isArmed)
        XCTAssertFalse(tap.isArmed, "the tap must let every key through while unarmed")

        // A person typing "y" in their editor as the prompt appears.
        tap.press(.yes)
        clock.advance(by: 0.1)
        tap.press(.timed)
        controller.choose(.allow)          // a stray click is ignored too
        clock.advance(by: 0.199)
        tap.press(.no)
        tap.press(.escape)
        XCTAssertEqual(controller.current, request(), "nothing answered in the first 300 ms")

        clock.advance(by: 0.01)
        XCTAssertTrue(controller.isArmed)
        XCTAssertTrue(tap.isArmed)
        tap.press(.yes)
        let outcome = await task.value
        XCTAssertEqual(outcome, .allow)
        XCTAssertNil(controller.current)
    }

    func test_y_allows_n_denies_a_timed_escape_denies() async {
        let cases: [(CaseApprovalKey, CaseApprovalOutcome)] = [
            (.yes, .allow), (.no, .deny), (.timed, .allowTimed), (.escape, .deny),
        ]
        for (key, expected) in cases {
            let task = await ask(request())
            clock.advance(by: 0.3)
            tap.press(key)
            let outcome = await task.value
            XCTAssertEqual(outcome, expected, "\(key)")
            XCTAssertNil(controller.current)
        }
    }

    func test_timeout_after_60s_denies() async {
        let task = await ask(request())
        clock.advance(by: 59.9)
        XCTAssertNotNil(controller.current, "still waiting before 60 s")
        XCTAssertEqual(controller.deadline, Date(timeIntervalSinceReferenceDate: 1_060))
        clock.advance(by: 0.1)
        let outcome = await task.value
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertNil(controller.current)
        XCTAssertFalse(tap.isRunning)

        // A key arriving after the timeout answers nothing.
        tap.press(.yes)
        XCTAssertNil(controller.current)
    }

    func test_queue_shows_one_at_a_time() async {
        let first = await ask(request("Claude Code", project: "alpha"))
        let second = await ask(request("Codex", project: "beta", keys: ["DB_URL", "DB_PASSWORD"]))
        let third = await ask(request("Cursor", project: "gamma"))

        XCTAssertEqual(controller.current?.appName, "Claude Code")
        XCTAssertEqual(controller.pendingCount, 2, "two more wait behind the visible one")

        clock.advance(by: 30)
        tap.press(.yes)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .allow)
        XCTAssertEqual(controller.current?.appName, "Codex", "FIFO")
        XCTAssertEqual(controller.pendingCount, 1)

        // The next prompt is armed afresh: a double Y does not answer it.
        XCTAssertFalse(controller.isArmed)
        tap.press(.yes)
        XCTAssertEqual(controller.current?.appName, "Codex")

        // Its 60 s start when it appears, not when it was queued.
        clock.advance(by: 59)
        XCTAssertEqual(controller.current?.appName, "Codex")
        tap.press(.no)
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .deny)

        XCTAssertEqual(controller.current?.appName, "Cursor")
        XCTAssertEqual(controller.pendingCount, 0)
        clock.advance(by: 60)
        let thirdOutcome = await third.value
        XCTAssertEqual(thirdOutcome, .timedOut)
        XCTAssertNil(controller.current)
    }

    func test_tap_stopped_when_queue_empty() async {
        XCTAssertEqual(tap.startCount, 0, "no tap while nothing is asked")

        let first = await ask(request())
        let second = await ask(request("Codex"))
        XCTAssertEqual(tap.startCount, 1)
        XCTAssertTrue(tap.isRunning)

        clock.advance(by: 0.3)
        tap.press(.no)
        _ = await first.value
        XCTAssertTrue(tap.isRunning, "the queue still has a prompt")
        XCTAssertEqual(tap.stopCount, 0)

        clock.advance(by: 0.3)
        tap.press(.yes)
        _ = await second.value
        XCTAssertFalse(tap.isRunning, "stopped once the queue is empty")
        XCTAssertEqual(tap.stopCount, 1)
        XCTAssertFalse(tap.isArmed)

        // A later request installs the tap again.
        let third = await ask(request())
        XCTAssertEqual(tap.startCount, 2)
        controller.resolve(.deny)
        _ = await third.value
        XCTAssertFalse(tap.isRunning)
    }

    // MARK: - Edge cases

    func test_prompt_works_by_click_when_tap_cannot_start() async {
        tap.failsToStart = true
        let task = await ask(request())
        XCTAssertNotNil(controller.current, "the prompt shows without Accessibility")
        XCTAssertFalse(controller.keysAvailable)
        clock.advance(by: 0.3)
        controller.choose(.allowTimed)
        let outcome = await task.value
        XCTAssertEqual(outcome, .allowTimed)
    }

    func test_click_answers_after_arming() async {
        let task = await ask(request())
        clock.advance(by: 0.3)
        controller.choose(.deny)
        let outcome = await task.value
        XCTAssertEqual(outcome, .deny)
    }

    func test_timed_key_ignored_when_minutes_not_positive() async {
        let task = await ask(request(minutes: 0))
        clock.advance(by: 0.3)
        XCTAssertFalse(controller.offersTimed)
        tap.press(.timed)
        controller.choose(.allowTimed)
        XCTAssertNotNil(controller.current, "no timed grant to offer")
        tap.press(.yes)
        let outcome = await task.value
        XCTAssertEqual(outcome, .allow)
    }

    func test_cancel_all_denies_every_waiting_request() async {
        let first = await ask(request())
        let second = await ask(request("Codex"))
        controller.cancelAll()
        let a = await first.value
        let b = await second.value
        XCTAssertEqual(a, .deny)
        XCTAssertEqual(b, .deny)
        XCTAssertNil(controller.current)
        XCTAssertFalse(tap.isRunning)
        clock.advance(by: 120)   // stale timers fire nothing
        await settle()
    }

    func test_resolve_without_prompt_is_ignored() {
        controller.resolve(.allow)
        XCTAssertNil(controller.current)
        XCTAssertEqual(tap.startCount, 0)
    }

    func test_active_flag_follows_queue() async {
        var changes: [Bool] = []
        let cancellable = controller.$current.map { $0 != nil }.removeDuplicates().sink { changes.append($0) }
        let task = await ask(request())
        controller.resolve(.deny)
        _ = await task.value
        XCTAssertEqual(changes, [false, true, false])
        cancellable.cancel()
    }

    // MARK: - Key filter (what the real tap swallows)

    private func down(_ code: Int, armed: Bool = true, flags: CGEventFlags = [], isRepeat: Bool = false,
                      _ filter: inout CaseApprovalKeyFilter) -> CaseApprovalKeyFilter.Decision {
        filter.decide(type: .keyDown, keyCode: Int64(code), flags: flags, isRepeat: isRepeat, armed: armed)
    }

    private func up(_ code: Int, armed: Bool = true, _ filter: inout CaseApprovalKeyFilter) -> CaseApprovalKeyFilter.Decision {
        filter.decide(type: .keyUp, keyCode: Int64(code), flags: [], isRepeat: false, armed: armed)
    }

    func test_filter_maps_physical_keys_on_any_layout() {
        XCTAssertEqual(CaseApprovalKeyFilter.key(forKeyCode: Int64(kVK_ANSI_Y)), .yes)
        XCTAssertEqual(CaseApprovalKeyFilter.key(forKeyCode: Int64(kVK_ANSI_N)), .no)
        XCTAssertEqual(CaseApprovalKeyFilter.key(forKeyCode: Int64(kVK_ANSI_A)), .timed)
        XCTAssertEqual(CaseApprovalKeyFilter.key(forKeyCode: Int64(kVK_Escape)), .escape)
        // Neighbours and Return are not approval keys.
        for code in [kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_B, kVK_ANSI_M, kVK_ANSI_S, kVK_Return, kVK_Space] {
            XCTAssertNil(CaseApprovalKeyFilter.key(forKeyCode: Int64(code)))
        }
    }

    func test_filter_swallows_only_the_four_keys_when_armed() {
        var filter = CaseApprovalKeyFilter()
        XCTAssertEqual(down(kVK_ANSI_Y, &filter), .init(swallow: true, key: .yes))
        XCTAssertEqual(up(kVK_ANSI_Y, &filter), .init(swallow: true, key: nil), "its key-up goes with it")
        XCTAssertEqual(down(kVK_ANSI_T, &filter), .init(swallow: false, key: nil))
        XCTAssertEqual(up(kVK_ANSI_T, &filter), .init(swallow: false, key: nil))
        XCTAssertEqual(down(kVK_Return, &filter), .init(swallow: false, key: nil))
        XCTAssertEqual(down(kVK_Escape, &filter), .init(swallow: true, key: .escape))
    }

    func test_filter_passes_everything_while_unarmed() {
        var filter = CaseApprovalKeyFilter()
        for code in [kVK_ANSI_Y, kVK_ANSI_N, kVK_ANSI_A, kVK_Escape] {
            XCTAssertEqual(down(code, armed: false, &filter), .init(swallow: false, key: nil))
        }
        // The key-up of a press that went through is not swallowed after arming either.
        XCTAssertEqual(up(kVK_ANSI_Y, armed: true, &filter), .init(swallow: false, key: nil))
    }

    func test_filter_leaves_shortcuts_with_command_control_option() {
        var filter = CaseApprovalKeyFilter()
        XCTAssertEqual(down(kVK_ANSI_A, flags: .maskCommand, &filter), .init(swallow: false, key: nil), "⌘A select all")
        XCTAssertEqual(down(kVK_ANSI_N, flags: .maskControl, &filter), .init(swallow: false, key: nil))
        XCTAssertEqual(down(kVK_ANSI_Y, flags: .maskAlternate, &filter), .init(swallow: false, key: nil))
        XCTAssertEqual(down(kVK_ANSI_Y, flags: .maskShift, &filter), .init(swallow: true, key: .yes))
    }

    func test_filter_autorepeat_of_a_key_held_before_the_prompt_passes() {
        var filter = CaseApprovalKeyFilter()
        XCTAssertEqual(down(kVK_ANSI_Y, isRepeat: true, &filter), .init(swallow: false, key: nil))
        // A repeat of a press we took is swallowed without answering again.
        XCTAssertEqual(down(kVK_ANSI_N, &filter), .init(swallow: true, key: .no))
        XCTAssertEqual(down(kVK_ANSI_N, isRepeat: true, &filter), .init(swallow: true, key: nil))
        XCTAssertEqual(up(kVK_ANSI_N, &filter), .init(swallow: true, key: nil))
        XCTAssertEqual(up(kVK_ANSI_N, &filter), .init(swallow: false, key: nil))
    }

    // MARK: - Island integration

    func test_case_approval_is_an_idle_blocker() {
        let clear = IslandIdleBlockers(
            dropFlowActive: false, agentPhaseActive: false, agentPanelVisible: false,
            meetingSuggestionActive: false, meetingRecordingActive: false, updateAvailable: false,
            justUpdatedVisible: false, nowPlayingActive: false, rightModifierHeld: false,
            programmaticHoverExpansion: false)
        XCTAssertFalse(clear.isBusy)
        var asking = clear
        asking.caseApprovalActive = true
        XCTAssertTrue(asking.isBusy)
    }

    func test_hover_drawer_does_not_open_over_the_prompt() {
        XCTAssertTrue(IslandHoverPolicy.allowsExpansion(meetingSuggestionActive: false))
        XCTAssertFalse(IslandHoverPolicy.allowsExpansion(meetingSuggestionActive: false, caseApprovalActive: true))
    }

    func test_help_lists_the_approval_keys() {
        let rows = HelpWindowContent.hotkeyRows(for: .defaults)
        func caps(_ title: String) -> [KeycapContent]? { rows.first { $0.title == title }?.contents }
        XCTAssertEqual(caps("Case — allow"), [.text("Y")])
        XCTAssertEqual(caps("Case — deny"), [.text("N")])
        XCTAssertEqual(caps("Case — allow for minutes"), [.text("A")])
        XCTAssertTrue(rows.first { $0.title == "Case — deny" }?.detail.contains("Escape") ?? false)
    }

    func test_view_copy() {
        let r = request("Claude Code", project: "alpha", keys: ["KEY_A", "KEY_B"], minutes: 15)
        XCTAssertEqual(CaseApprovalView.titleText(r), "Claude Code хочет запустить команду")
        XCTAssertEqual(CaseApprovalView.keysText(r), "alpha: KEY_A, KEY_B")
        XCTAssertEqual(CaseApprovalView.timedTitle(minutes: 15), "На 15 мин")
        XCTAssertEqual(CaseApprovalView.commandLine("git push\n  --force"), "git push --force",
                       "one line, whitespace collapsed")
    }
}

/// Offscreen layout checks of the prompt card; never orders a window front.
/// Set EXODIA_CASE_PROOF_DIR to also write PNGs.
@MainActor
final class CaseApprovalViewRenderTests: XCTestCase {
    private func render(_ request: CaseApprovalRequest, width: CGFloat, pending: Int = 0, armed: Bool = true,
                        name: String) throws -> CGSize {
        _ = NSApplication.shared
        let card = CaseApprovalView(request: request, width: width, pendingCount: pending, isArmed: armed,
                                    onChoose: { _ in })
        let measure = NSHostingView(rootView: card)
        let cardSize = measure.fittingSize

        // The card under a stand-in for the island, on a light desktop.
        let scene = VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                   topTrailingRadius: 0).fill(Color.black).frame(width: width, height: 32)
            card
        }
        .padding(24)
        .background(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.74)],
                                   startPoint: .top, endPoint: .bottom))
        let host = NSHostingView(rootView: scene)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: host.frame.width,
                                                  height: host.frame.height),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible || window.isKeyWindow, "renders stay offscreen")

        if let output = ProcessInfo.processInfo.environment["EXODIA_CASE_PROOF_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        window.contentView = nil
        window.close()
        return cardSize
    }

    func test_card_keeps_island_width_and_one_line_command() throws {
        let short = CaseApprovalRequest(appName: "Claude Code", projectName: "whytap",
                                        keyNames: ["OPENROUTER_API_KEY", "SONIOX_API_KEY"],
                                        command: "swift test --filter CaseBrokerTests", timedMinutes: 15)
        let long = CaseApprovalRequest(
            appName: "Visual Studio Code Insiders", projectName: "terra-hiring-production-backend",
            keyNames: ["POSTGRES_PASSWORD", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "JWT_SECRET"],
            command: "docker compose -f deploy/compose.prod.yml run --rm migrate && ./scripts/seed.sh --env production --force",
            timedMinutes: 240)
        let noTimed = CaseApprovalRequest(appName: "Codex", projectName: "alpha", keyNames: ["DB_URL"],
                                          command: "psql \"$DB_URL\" -c 'select 1'", timedMinutes: 0)

        let a = try render(short, width: 312, name: "case-approval-312")
        let b = try render(long, width: 310, pending: 2, name: "case-approval-310-long-queue")
        let c = try render(noTimed, width: 312, name: "case-approval-312-no-timed")
        let d = try render(short, width: 312, armed: false, name: "case-approval-312-arming")

        for size in [a, b, c, d] {
            XCTAssertLessThanOrEqual(size.width, 312.5)
            XCTAssertLessThan(size.height, 140, "a compact card")
        }
        XCTAssertEqual(a.height, b.height, accuracy: 0.5, "long text truncates instead of wrapping")
        XCTAssertEqual(a.height, c.height, accuracy: 0.5)
    }
}
