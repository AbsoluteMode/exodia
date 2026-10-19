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
    private var session: BrightnessKeyTapSession?

    func start(deliver: @escaping @MainActor (BrightnessKeyEvent) -> Void,
               onFailure: @escaping @MainActor () -> Void) -> Bool {
        stop()
        let session = BrightnessKeyTapSession(deliver: deliver, onFailure: onFailure, intercepting: intercepting)
        session.owner = self
        // The callback can run as soon as the tap exists.
        activeBrightnessKeyTapSession.withLock { $0 = session }
        guard session.thread.installTap(mask: CGEventMask(1) << systemDefinedEventType,
                                        callback: brightnessKeyTapCallback) != nil else {
            activeBrightnessKeyTapSession.withLock { if $0 === session { $0 = nil } }
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

/// One installed tap. The callbacks it was started with never change; its filter is locked
/// because a callback can still be finishing on a stopped tap's thread.
private final class BrightnessKeyTapSession: @unchecked Sendable {
    struct TapState {
        var filter = BrightnessKeyFilter()
        var reenables = 0
    }

    let thread = SpaceHoldMonitor.TapThread(queueLabel: "com.rootwise.sidekey.brightness-keys-tap")
    let deliver: @MainActor (BrightnessKeyEvent) -> Void
    let onFailure: @MainActor () -> Void
    let intercepting: OSAllocatedUnfairLock<Bool>
    let state = OSAllocatedUnfairLock(initialState: TapState())
    /// Main thread only.
    weak var owner: BrightnessKeyEventTap?

    init(deliver: @escaping @MainActor (BrightnessKeyEvent) -> Void, onFailure: @escaping @MainActor () -> Void,
         intercepting: OSAllocatedUnfairLock<Bool>) {
        self.deliver = deliver
        self.onFailure = onFailure
        self.intercepting = intercepting
    }
}

private func brightnessKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                      userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let unchanged = Unmanaged.passUnretained(event)
    guard let session = activeBrightnessKeyTapSession.withLock({ $0 }) else { return unchanged }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let attempt = session.state.withLock { state in
            state.reenables += 1
            return state.reenables
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.owner?.tapWasDisabled(session, attempt: attempt) }
        }
        return unchanged
    }
    guard type.rawValue == systemDefinedEventType else { return unchanged }
    let key = BrightnessKeyEvent(systemDefined: event)
    let intercepting = session.intercepting.withLock { $0 }
    let swallow = session.state.withLock { state in
        // Events arrive, so the tap works.
        state.reenables = 0
        return key.map { state.filter.shouldSwallow($0, intercepting: intercepting) } ?? false
    }
    guard swallow, let key else { return unchanged }
    if key.isDown {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.deliver(key) }
        }
    }
    return nil
}
