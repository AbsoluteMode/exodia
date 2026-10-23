import AppKit
import XCTest
@testable import Sidekey

/// The answer close interceptor must react to BARE Escape only.
/// Modified Escape chords (⌘⎋, ⌥⎋, …) are other apps' / the system's
/// shortcuts, and non-Escape keys must never trigger the close.
final class EscapeCloseEventMonitorTests: XCTestCase {
    func testBareEscapeTriggers() {
        XCTAssertTrue(EscapeCloseEventMonitor.isBareEscape(keyCode: 53, modifierFlags: []))
    }

    func testModifiedEscapeChordsDoNotTrigger() {
        for flags in [NSEvent.ModifierFlags.command, .option, .control, .shift] {
            XCTAssertFalse(
                EscapeCloseEventMonitor.isBareEscape(keyCode: 53, modifierFlags: flags),
                "Escape with \(flags) is a chord, not the bare close key"
            )
        }
    }

    func testKeyboardStateModifiersDoNotBlockEscape() {
        // Caps Lock / fn are keyboard state, not a chord — Esc stays bare Esc.
        XCTAssertTrue(EscapeCloseEventMonitor.isBareEscape(keyCode: 53, modifierFlags: [.capsLock]))
        XCTAssertTrue(EscapeCloseEventMonitor.isBareEscape(keyCode: 53, modifierFlags: [.function]))
    }

    func testOtherKeysDoNotTrigger() {
        XCTAssertFalse(EscapeCloseEventMonitor.isBareEscape(keyCode: 12, modifierFlags: []))
        XCTAssertFalse(EscapeCloseEventMonitor.isBareEscape(keyCode: 0, modifierFlags: []))
    }

    func testOnlyFirstAnswerPressIsConsumedThroughRelease() {
        var filter = EscapeCloseKeyFilter()
        XCTAssertFalse(filter.decide(type: .keyDown, keyCode: 53, flags: [], isRepeat: false).swallow)
        filter.showAnswer()
        let first = filter.decide(type: .keyDown, keyCode: 53, flags: [], isRepeat: false)
        XCTAssertTrue(first.swallow)
        XCTAssertNotNil(first.closeGeneration)
        filter.hideAnswer()
        let repeated = filter.decide(type: .keyDown, keyCode: 53, flags: .maskCommand, isRepeat: true)
        XCTAssertTrue(repeated.swallow)
        XCTAssertNil(repeated.closeGeneration)
        XCTAssertTrue(filter.decide(type: .keyUp, keyCode: 53, flags: [], isRepeat: false).swallow)
        XCTAssertFalse(filter.needsTap)
        XCTAssertFalse(filter.decide(type: .keyDown, keyCode: 53, flags: [], isRepeat: false).swallow)
        XCTAssertFalse(filter.decide(type: .keyUp, keyCode: 53, flags: [], isRepeat: false).swallow)
    }

    func testPreheldEscapeAndModifiedChordsStayWithUnderlyingApp() {
        var filter = EscapeCloseKeyFilter()
        filter.showAnswer()
        XCTAssertFalse(filter.decide(type: .keyDown, keyCode: 53, flags: [], isRepeat: true).swallow)
        XCTAssertFalse(filter.decide(type: .keyUp, keyCode: 53, flags: [], isRepeat: false).swallow)
        for flags in [CGEventFlags.maskCommand, .maskAlternate, .maskControl, .maskShift] {
            XCTAssertFalse(filter.decide(type: .keyDown, keyCode: 53, flags: flags, isRepeat: false).swallow)
            XCTAssertFalse(filter.decide(type: .keyUp, keyCode: 53, flags: flags, isRepeat: false).swallow)
        }
        XCTAssertFalse(filter.decide(type: .keyDown, keyCode: 0, flags: [], isRepeat: false).swallow)
        XCTAssertTrue(filter.answerVisible)
        XCTAssertTrue(filter.decide(type: .keyDown, keyCode: 53, flags: .maskAlphaShift, isRepeat: false).swallow)
    }

    func testMissingReleaseCannotStealNextPhysicalPress() {
        var filter = EscapeCloseKeyFilter()
        filter.showAnswer()
        XCTAssertTrue(filter.decide(type: .keyDown, keyCode: 53, flags: [], isRepeat: false).swallow)
        filter.hideAnswer()
        XCTAssertFalse(filter.decide(type: .keyDown, keyCode: 53, flags: [], isRepeat: false).swallow)
        XCTAssertFalse(filter.needsTap)
    }
}

/// Synthetic events enter a fake tap callback directly; never post input or
/// install an event tap in the user's session.
@MainActor
final class EscapeCloseTapLifecycleTests: XCTestCase {
    func testDismissalDrainsPressThenDisposesTapAndPassesNextEscape() async throws {
        let tap = FakeEscapeCloseTap()
        var held = true
        let monitor = EscapeCloseEventMonitor(tap: tap, escapeIsDown: { held })
        var closes = 0
        monitor.setOnHotkey { [weak monitor] in closes += 1; monitor?.stop() }
        try monitor.start()
        XCTAssertTrue(tap.send(.keyDown))
        XCTAssertEqual(closes, 0, "Close is deferred off the event tap thread")
        await settle()
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(tap.stops, 0, "Retain ownership until this press finishes")
        XCTAssertTrue(tap.send(.keyDown, isRepeat: true))
        XCTAssertFalse(tap.send(.keyDown, keyCode: 0))
        held = false
        XCTAssertTrue(tap.send(.keyUp))
        await settle()
        XCTAssertEqual(tap.stops, 1)
        XCTAssertFalse(tap.send(.keyDown))
        XCTAssertFalse(tap.send(.keyUp))
        XCTAssertEqual(closes, 1)
    }

    func testClickDismissalImmediatelyReleasesEscape() throws {
        let tap = FakeEscapeCloseTap()
        let monitor = EscapeCloseEventMonitor(tap: tap, escapeIsDown: { false })
        monitor.setOnHotkey {}
        try monitor.start()
        monitor.stop()
        XCTAssertEqual(tap.stops, 1)
        XCTAssertFalse(tap.send(.keyDown))
    }

    func testSuspendedAnswerLetsDropCancelWithoutTranscribingOnRelease() throws {
        let tap = FakeEscapeCloseTap()
        let monitor = EscapeCloseEventMonitor(tap: tap, escapeIsDown: { false })
        monitor.setOnHotkey { XCTFail("The answer must not take Drop's cancel") }
        try monitor.start()
        var drop = SpaceHoldDetector()
        _ = drop.handle(.spaceKeyDown(isRepeat: false))
        _ = drop.handle(.thresholdFired)
        _ = drop.handle(.editableResolved(isEditable: true))
        XCTAssertEqual(drop.state, .armed)
        monitor.stop() // The interaction publisher suspends answer ownership.
        XCTAssertFalse(tap.send(.keyDown))
        XCTAssertEqual(drop.handle(.escapeKeyDown), [.cancelDrop])
        XCTAssertFalse(drop.handle(.spaceKeyUp).contains(.stopAndTranscribe))
    }

    func testMissingKeyUpIsCleanedWithoutStealingAnotherPress() async throws {
        let tap = FakeEscapeCloseTap()
        var held = true
        let monitor = EscapeCloseEventMonitor(tap: tap, escapeIsDown: { held })
        monitor.setOnHotkey { [weak monitor] in monitor?.stop() }
        try monitor.start()
        XCTAssertTrue(tap.send(.keyDown))
        await settle()
        held = false
        monitor.releaseFinishedPress()
        XCTAssertEqual(tap.stops, 1)
        XCTAssertFalse(tap.send(.keyDown))
    }

    func testOldQueuedCloseCannotDismissNewAnswer() async throws {
        let tap = FakeEscapeCloseTap()
        let monitor = EscapeCloseEventMonitor(tap: tap, escapeIsDown: { true })
        var closes = 0
        monitor.setOnHotkey { [weak monitor] in closes += 1; monitor?.stop() }
        try monitor.start()
        XCTAssertTrue(tap.send(.keyDown))
        monitor.stop()
        try monitor.start()
        await settle()
        XCTAssertEqual(closes, 0)
        XCTAssertEqual(tap.installs, 1, "Reuse the draining tap for the new answer")
        XCTAssertTrue(tap.send(.keyDown, isRepeat: true))
        XCTAssertTrue(tap.send(.keyUp))
        await settle()
        XCTAssertEqual(tap.stops, 0)
        XCTAssertTrue(tap.send(.keyDown))
        await settle()
        XCTAssertEqual(closes, 1)
        _ = tap.send(.keyUp)
        await settle()
    }

    func testUnavailableTapDoesNotFallBackToDoubleAction() {
        let tap = FakeEscapeCloseTap()
        tap.available = false
        let monitor = EscapeCloseEventMonitor(tap: tap)
        monitor.setOnHotkey { XCTFail("Unavailable interception must not passively close too") }
        XCTAssertThrowsError(try monitor.start())
        XCTAssertFalse(tap.send(.keyDown))
    }

    func testReleaseBeforeMainQueueDismissalStillClosesOnce() async throws {
        let tap = FakeEscapeCloseTap()
        let monitor = EscapeCloseEventMonitor(tap: tap, escapeIsDown: { false })
        var closes = 0
        monitor.setOnHotkey { [weak monitor] in closes += 1; monitor?.stop() }
        try monitor.start()
        XCTAssertTrue(tap.send(.keyDown))
        XCTAssertTrue(tap.send(.keyUp))
        await settle()
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(tap.stops, 1)
        XCTAssertFalse(tap.send(.keyDown))
    }

    func testRevokedPermissionStopsInsteadOfPersistentlyReenabling() async throws {
        let tap = FakeEscapeCloseTap()
        let monitor = EscapeCloseEventMonitor(tap: tap, escapeIsDown: { false }, canReenable: { false })
        monitor.setOnHotkey { XCTFail("A disabled tap must not dismiss through passive observation") }
        try monitor.start()
        XCTAssertFalse(tap.send(.tapDisabledByTimeout))
        await settle()
        XCTAssertEqual(tap.stops, 1)
        XCTAssertFalse(tap.send(.keyDown))
    }

    func testControllerReleaseClearsGlobalSession() async throws {
        let tap = FakeEscapeCloseTap()
        var monitor: EscapeCloseEventMonitor? = EscapeCloseEventMonitor(tap: tap, escapeIsDown: { false })
        monitor?.setOnHotkey {}
        try monitor?.start()
        monitor = nil
        XCTAssertFalse(tap.send(.keyDown))
        await settle()
        XCTAssertEqual(tap.stops, 1)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
private final class FakeEscapeCloseTap: EscapeCloseTapDriving {
    var available = true
    var installs = 0
    var stops = 0
    private var callback: CGEventTapCallBack?

    func install(callback: @escaping CGEventTapCallBack) -> Bool {
        self.callback = callback
        installs += 1
        return available
    }

    func enable(_ enabled: Bool) { if !enabled { stops += 1 } }

    func send(_ type: CGEventType, keyCode: CGKeyCode = 53, flags: CGEventFlags = [], isRepeat: Bool = false) -> Bool {
        guard let callback, let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: type == .keyDown)
        else { return false }
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
        return callback(OpaquePointer(bitPattern: 1)!, type, event, nil) == nil
    }
}
