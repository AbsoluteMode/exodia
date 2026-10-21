import AppKit
import Carbon.HIToolbox
import CoreGraphics
import os

/// Fixed digit keys for a Case Approve prompt; shared by the tap, card and Help.
enum CaseApprovalKey: Equatable {
    case yes, no, timed

    var keycap: String {
        switch self {
        case .no: "1"
        case .yes: "2"
        case .timed: "3"
        }
    }
}

enum CaseApprovalKeyTapError: Error {
    /// No event tap (usually Accessibility is not granted). The prompt still works by click.
    case unavailable
}

/// Intercepts the answer keys while an Approve prompt is on screen.
@MainActor
protocol CaseApprovalKeyIntercepting: AnyObject {
    /// `onUnarmedKeyDown` reports that some key went down while unarmed (which key
    /// is never passed on), so the controller can restart its quiet period.
    func start(onKey: @escaping @MainActor (CaseApprovalKey) -> Void,
               onUnarmedKeyDown: @escaping @MainActor () -> Void) throws
    func stop()
    /// Unarmed, every key goes through untouched (until the keyboard is quiet for 300 ms).
    func setArmed(_ armed: Bool)
}

/// Pure per-event decision of the approval tap: which events are swallowed and
/// which press answers the prompt. Only bare 1, 2 and 3 are ever swallowed.
struct CaseApprovalKeyFilter {
    struct Decision: Equatable {
        var swallow: Bool
        var key: CaseApprovalKey?
    }

    private static let pass = Decision(swallow: false, key: nil)

    /// Keys whose press we swallowed; their repeats and key-up go with them, so the
    /// app underneath never sees half a keystroke.
    private var held: Set<Int64> = []

    static func key(forKeyCode keyCode: Int64) -> CaseApprovalKey? {
        // WHY: docs/decisions/2026-10-21-case-numeric-approval.md
        switch keyCode {
        case Int64(kVK_ANSI_1), Int64(kVK_ANSI_Keypad1): .no
        case Int64(kVK_ANSI_2), Int64(kVK_ANSI_Keypad2): .yes
        case Int64(kVK_ANSI_3), Int64(kVK_ANSI_Keypad3): .timed
        default: nil
        }
    }

    mutating func decide(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool,
                         armed: Bool) -> Decision {
        switch type {
        case .keyUp:
            return held.remove(keyCode) != nil ? Decision(swallow: true, key: nil) : Self.pass
        case .keyDown:
            guard let key = Self.key(forKeyCode: keyCode) else { return Self.pass }
            if held.contains(keyCode) { return Decision(swallow: true, key: nil) }
            // A repeat of a key held down before the prompt (or before arming) stays with the app.
            guard !isRepeat, armed else { return Self.pass }
            // Modified digits belong to the app (including Shift's punctuation).
            guard flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { return Self.pass }
            held.insert(keyCode)
            return Decision(swallow: true, key: key)
        default:
            return Self.pass
        }
    }
}

/// Active session event tap for the approval keys, on its own thread, installed
/// only while the approval queue is non-empty. Follows `SpaceHoldMonitor`: keycode
/// match, swallow by returning nil. Nothing about any key is logged or stored.
@MainActor
final class CaseApprovalKeyTap: CaseApprovalKeyIntercepting {
    /// A tap macOS keeps disabling with no event in between is given up, as in SpaceHoldMonitor.
    static let maxConsecutiveReenables = 3

    private var session: CaseApprovalKeyTapSession?

    func start(onKey: @escaping @MainActor (CaseApprovalKey) -> Void,
               onUnarmedKeyDown: @escaping @MainActor () -> Void) throws {
        stop()
        let session = CaseApprovalKeyTapSession(onKey: onKey, onUnarmedKeyDown: onUnarmedKeyDown)
        session.owner = self
        activeCaseApprovalKeyTapSession.withLock { $0 = session }
        guard session.thread.installTap(callback: caseApprovalKeyTapCallback) != nil else {
            activeCaseApprovalKeyTapSession.withLock { if $0 === session { $0 = nil } }
            throw CaseApprovalKeyTapError.unavailable
        }
        self.session = session
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        activeCaseApprovalKeyTapSession.withLock { if $0 === session { $0 = nil } }
        session.thread.enableTap(false)
    }

    func setArmed(_ armed: Bool) {
        session?.armed.withLock { $0 = armed }
    }

    fileprivate func tapWasDisabled(_ disabled: CaseApprovalKeyTapSession, attempt: Int) {
        guard session === disabled else { return }
        // Re-enabling a tap without Accessibility lags all input, so it is given up;
        // the prompt stays answerable by click.
        if attempt <= Self.maxConsecutiveReenables, AXIsProcessTrusted() {
            disabled.thread.enableTap(true)
        } else {
            stop()
        }
    }
}

/// The installed tap, for the C callback, which cannot capture it.
private let activeCaseApprovalKeyTapSession = OSAllocatedUnfairLock<CaseApprovalKeyTapSession?>(initialState: nil)

/// One installed tap. State is locked because the callback runs on the tap thread.
private final class CaseApprovalKeyTapSession: @unchecked Sendable {
    let thread = SpaceHoldMonitor.TapThread(queueLabel: "com.rootwise.sidekey.case-approval-tap")
    let onKey: @MainActor (CaseApprovalKey) -> Void
    let onUnarmedKeyDown: @MainActor () -> Void
    let armed = OSAllocatedUnfairLock(initialState: false)
    let filter = OSAllocatedUnfairLock(initialState: CaseApprovalKeyFilter())
    let reenables = OSAllocatedUnfairLock(initialState: 0)
    /// Main thread only.
    weak var owner: CaseApprovalKeyTap?

    init(onKey: @escaping @MainActor (CaseApprovalKey) -> Void,
         onUnarmedKeyDown: @escaping @MainActor () -> Void) {
        self.onKey = onKey
        self.onUnarmedKeyDown = onUnarmedKeyDown
    }
}

private func caseApprovalKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                        userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let unchanged = Unmanaged.passUnretained(event)
    guard let session = activeCaseApprovalKeyTapSession.withLock({ $0 }) else { return unchanged }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let attempt = session.reenables.withLock { count in
            count += 1
            return count
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.owner?.tapWasDisabled(session, attempt: attempt) }
        }
        return unchanged
    }
    guard type == .keyDown || type == .keyUp else { return unchanged }
    session.reenables.withLock { $0 = 0 }
    let armed = session.armed.withLock { $0 }
    let decision = session.filter.withLock {
        $0.decide(type: type,
                  keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                  flags: event.flags,
                  isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                  armed: armed)
    }
    if let key = decision.key {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.onKey(key) }
        }
    } else if type == .keyDown, !armed {
        // Someone is typing: the prompt waits for a quiet keyboard before it arms.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.onUnarmedKeyDown() }
        }
    }
    return decision.swallow ? nil : unchanged
}
