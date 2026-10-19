import AppKit
import CoreGraphics
import os

/// The session event tap behind Brightness keys, on its own thread. It asks only for
/// system-defined events and returns every event untouched except the brightness presses
/// Exodia keeps. Nothing about an event is logged or stored.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
final class BrightnessKeyEventTap: BrightnessKeyTapping {
    /// A tap macOS keeps disabling with no event in between is given up, as in SpaceHoldMonitor.
    static let maxConsecutiveReenables = 3

    private let intercepting = OSAllocatedUnfairLock(initialState: false)
    /// The presses outlive each installed tap: the hotkeys' rebuild replaces it while a key
    /// can be held.
    private let presses = OSAllocatedUnfairLock(initialState: BrightnessKeyFilter())
    private var session: BrightnessKeyTapSession?

    func start(deliver: @escaping @MainActor (BrightnessKeyEvent, Date) -> Void,
               onFailure: @escaping @MainActor () -> Void) -> Bool {
        stop()
        let session = BrightnessKeyTapSession(deliver: deliver, onFailure: onFailure, intercepting: intercepting,
                                              presses: presses)
        session.owner = self
        // The callback can run as soon as the tap exists, so the presses are settled first.
        presses.withLock { $0.resumeWatching(at: ProcessInfo.processInfo.systemUptime) }
        activeBrightnessKeyTapSession.withLock { $0 = session }
        guard session.thread.installTap(mask: CGEventMask(1) << systemDefinedEventType,
                                        callback: brightnessKeyTapCallback) != nil else {
            activeBrightnessKeyTapSession.withLock { if $0 === session { $0 = nil } }
            // Without a tap the presses in progress finish with macOS.
            presses.withLock { $0.forgetPresses() }
            return false
        }
        self.session = session
        return true
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        activeBrightnessKeyTapSession.withLock { if $0 === session { $0 = nil } }
        session.thread.enableTap(false)
        presses.withLock { $0.stopWatching(at: ProcessInfo.processInfo.systemUptime) }
    }

    func setIntercepting(_ intercepting: Bool) {
        self.intercepting.withLock { $0 = intercepting }
    }

    fileprivate func tapWasDisabled(_ disabled: BrightnessKeyTapSession, attempt: Int) {
        guard session === disabled else { return }
        // Re-enabling a tap without Accessibility lags all input, so it is given up instead.
        if attempt <= Self.maxConsecutiveReenables, AXIsProcessTrusted() {
            disabled.thread.enableTap(true)
        } else {
            stop()
            disabled.onFailure()
        }
    }
}

extension BrightnessKeyEvent {
    /// Nil for any event other than a brightness key.
    init?(systemDefined event: CGEvent) {
        // NSEvent raises for subtype and data1 of other event types.
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined,
              let key = Self.parse(subtype: nsEvent.subtype.rawValue, data1: nsEvent.data1, flags: event.flags)
        else { return nil }
        self = key
    }
}

/// NX_SYSDEFINED, which CGEventType has no case for.
private let systemDefinedEventType: UInt32 = 14

/// The installed tap, for the C callback, which cannot capture it.
private let activeBrightnessKeyTapSession = OSAllocatedUnfairLock<BrightnessKeyTapSession?>(initialState: nil)

/// One installed tap. The callbacks it was started with never change. The interception and
/// the presses belong to the tap object; like the reenable count they are locked because a
/// callback can still be finishing on a stopped tap's thread.
private final class BrightnessKeyTapSession: @unchecked Sendable {
    let thread = SpaceHoldMonitor.TapThread(queueLabel: "com.rootwise.sidekey.brightness-keys-tap")
    let deliver: @MainActor (BrightnessKeyEvent, Date) -> Void
    let onFailure: @MainActor () -> Void
    let intercepting: OSAllocatedUnfairLock<Bool>
    let presses: OSAllocatedUnfairLock<BrightnessKeyFilter>
    let reenables = OSAllocatedUnfairLock(initialState: 0)
    /// Main thread only.
    weak var owner: BrightnessKeyEventTap?

    init(deliver: @escaping @MainActor (BrightnessKeyEvent, Date) -> Void, onFailure: @escaping @MainActor () -> Void,
         intercepting: OSAllocatedUnfairLock<Bool>, presses: OSAllocatedUnfairLock<BrightnessKeyFilter>) {
        self.deliver = deliver
        self.onFailure = onFailure
        self.intercepting = intercepting
        self.presses = presses
    }
}

private func brightnessKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                      userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let unchanged = Unmanaged.passUnretained(event)
    guard let session = activeBrightnessKeyTapSession.withLock({ $0 }) else { return unchanged }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Events go past the disabled tap until it is enabled again.
        session.presses.withLock { $0.forgetPresses() }
        let attempt = session.reenables.withLock { count in
            count += 1
            return count
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.owner?.tapWasDisabled(session, attempt: attempt) }
        }
        return unchanged
    }
    guard type.rawValue == systemDefinedEventType else { return unchanged }
    // Events arrive, so the tap works.
    session.reenables.withLock { $0 = 0 }
    guard let key = BrightnessKeyEvent(systemDefined: event) else { return unchanged }
    let intercepting = session.intercepting.withLock { $0 }
    guard session.presses.withLock({ $0.shouldSwallow(key, intercepting: intercepting) }) else { return unchanged }
    if key.isDown {
        // The main thread can be busy, so the press keeps the time it happened.
        let pressedAt = Date()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.deliver(key, pressedAt) }
        }
    }
    return nil
}
