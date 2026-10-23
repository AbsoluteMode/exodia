import AppKit
import CoreGraphics
import os

/// One visible answer owns one fresh bare Escape press. Repeats and key-up
/// belong to that same press; a later press belongs to the underlying app.
struct EscapeCloseKeyFilter {
    struct Decision {
        var swallow = false
        var closeGeneration: UInt64?
    }

    private(set) var answerVisible = false
    private(set) var consumingPress = false
    private(set) var generation: UInt64 = 0
    var needsTap: Bool { answerVisible || consumingPress }

    mutating func showAnswer() {
        generation &+= 1
        answerVisible = true
    }

    mutating func hideAnswer() {
        generation &+= 1
        answerVisible = false
    }

    mutating func releasePress() { consumingPress = false }

    mutating func decide(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Decision {
        guard keyCode == 53 else { return Decision() }
        switch type {
        case .keyUp:
            let swallowed = consumingPress
            consumingPress = false
            return Decision(swallow: swallowed)
        case .keyDown:
            if consumingPress, isRepeat { return Decision(swallow: true) }
            // A new physical press also clears a stale latch if a tap outage
            // lost the old key-up. It must never steal an extra Escape.
            if !isRepeat { consumingPress = false }
            guard answerVisible, !isRepeat,
                  flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
            else { return Decision() }
            answerVisible = false
            consumingPress = true
            return Decision(swallow: true, closeGeneration: generation)
        default:
            return Decision()
        }
    }
}

@MainActor
protocol EscapeCloseTapDriving: AnyObject {
    func install(callback: @escaping CGEventTapCallBack) -> Bool
    func enable(_ enabled: Bool)
}

@MainActor
private final class SystemEscapeCloseTap: EscapeCloseTapDriving {
    private let thread = SpaceHoldMonitor.TapThread(queueLabel: "com.rootwise.sidekey.agent-escape-tap")

    func install(callback: @escaping CGEventTapCallBack) -> Bool {
        // A library/test host must never install an active global input filter.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        return thread.installTap(callback: callback) != nil
    }

    func enable(_ enabled: Bool) { thread.enableTap(enabled) }
}

enum EscapeCloseEventMonitorError: Error { case unavailable }

/// Installed only for a visible answer, independent of which app has focus.
/// A consumed press drains through key-up after dismissal, then the tap stops.
/// WHY: docs/decisions/2026-10-23-agent-answer-escape-consumption.md
@MainActor
final class EscapeCloseEventMonitor: AgentResponseCloseHotkeyControlling {
    private let tap: EscapeCloseTapDriving
    private let escapeIsDown: () -> Bool
    private let canReenable: () -> Bool
    private var session: EscapeCloseTapSession?
    private var releaseTimer: Timer?
    private var onHotkey: (() -> Void)?

    init(tap: EscapeCloseTapDriving? = nil, escapeIsDown: @escaping () -> Bool = {
        // Read hardware state, upstream of the session tap's consumption.
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(53))
    }, canReenable: @escaping () -> Bool = AXIsProcessTrusted) {
        self.tap = tap ?? SystemEscapeCloseTap()
        self.escapeIsDown = escapeIsDown
        self.canReenable = canReenable
    }

    deinit {
        releaseTimer?.invalidate()
        if let session {
            activeEscapeCloseTapSession.withLock { if $0 === session { $0 = nil } }
            // TapThread has no actor-bound work; dispose directly at teardown.
            session.dispose()
        }
    }

    nonisolated static func isBareEscape(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        keyCode == 53 && modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    func setOnHotkey(_ handler: @escaping () -> Void) { onHotkey = handler }

    func start() throws {
        guard onHotkey != nil else { throw EscapeCloseEventMonitorError.unavailable }
        releaseTimer?.invalidate()
        releaseTimer = nil
        if let session {
            session.filter.withLock { $0.showAnswer() }
            return
        }
        let next = EscapeCloseTapSession()
        next.owner = self
        next.filter.withLock { $0.showAnswer() }
        // Capturing the driver in a main-queue disposal closure keeps native
        // teardown on its owner queue even if the controller is released.
        next.dispose = { [tap] in
            DispatchQueue.main.async { MainActor.assumeIsolated { tap.enable(false) } }
        }
        guard activeEscapeCloseTapSession.withLock({ active in
            guard active == nil else { return false }
            active = next
            return true
        }) else { throw EscapeCloseEventMonitorError.unavailable }
        guard tap.install(callback: escapeCloseTapCallback) else {
            activeEscapeCloseTapSession.withLock { if $0 === next { $0 = nil } }
            tap.enable(false)
            throw EscapeCloseEventMonitorError.unavailable
        }
        session = next
    }

    func stop() {
        guard let session else { return }
        session.filter.withLock { $0.hideAnswer() }
        if !session.filter.withLock({ $0.consumingPress }) {
            finishIfUnused(session)
        } else {
            // Normally key-up tears down immediately. This bounded-scope
            // timer also releases a latch when macOS dropped that event.
            releaseTimer?.invalidate()
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseFinishedPress() }
            }
            releaseTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func releaseFinishedPress() {
        guard let session, !escapeIsDown() else { return }
        session.filter.withLock { $0.releasePress() }
        finishIfUnused(session)
    }

    fileprivate func close(_ source: EscapeCloseTapSession, generation: UInt64) {
        guard session === source,
              source.filter.withLock({ $0.generation == generation }) else { return }
        onHotkey?()
    }

    fileprivate func finishIfUnused(_ source: EscapeCloseTapSession) {
        guard session === source, !source.filter.withLock({ $0.needsTap }) else { return }
        releaseTimer?.invalidate()
        releaseTimer = nil
        activeEscapeCloseTapSession.withLock { if $0 === source { $0 = nil } }
        session = nil
        tap.enable(false)
    }

    fileprivate func tapWasDisabled(_ source: EscapeCloseTapSession, attempt: Int) {
        guard session === source else { return }
        if !escapeIsDown() { source.filter.withLock { $0.releasePress() } }
        guard source.filter.withLock({ $0.needsTap }) else { finishIfUnused(source); return }
        if attempt <= 3, canReenable() {
            tap.enable(true)
        } else {
            os_log("escape_close_tap_unavailable", log: OSLog(subsystem: "com.rootwise.sidekey", category: "hotkey"), type: .error)
            source.filter.withLock { $0.hideAnswer(); $0.releasePress() }
            finishIfUnused(source)
        }
    }
}

private let activeEscapeCloseTapSession = OSAllocatedUnfairLock<EscapeCloseTapSession?>(initialState: nil)

private final class EscapeCloseTapSession: @unchecked Sendable {
    let filter = OSAllocatedUnfairLock(initialState: EscapeCloseKeyFilter())
    let reenables = OSAllocatedUnfairLock(initialState: 0)
    // Accessed on the main queue only.
    weak var owner: EscapeCloseEventMonitor?
    var dispose: () -> Void = {}
}

private func escapeCloseTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                    userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let unchanged = Unmanaged.passUnretained(event)
    guard let session = activeEscapeCloseTapSession.withLock({ $0 }) else { return unchanged }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let attempt = session.reenables.withLock { $0 += 1; return $0 }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.owner?.tapWasDisabled(session, attempt: attempt) }
        }
        return unchanged
    }
    guard type == .keyDown || type == .keyUp else { return unchanged }
    session.reenables.withLock { $0 = 0 }
    let decision = session.filter.withLock {
        $0.decide(type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                  isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    }
    if let generation = decision.closeGeneration {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.owner?.close(session, generation: generation) }
        }
    }
    if !session.filter.withLock({ $0.needsTap }) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.owner?.finishIfUnused(session) }
        }
    }
    return decision.swallow ? nil : unchanged
}
