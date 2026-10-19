import AppKit
import XCTest
@testable import Sidekey

/// Without focus, WindowServer keeps the boost layer's EDR headroom only about 0.8 s after
/// its last frame, so the overlay presents frames on its own instead of waiting for the strip.
@MainActor
final class BrightnessBoostFrameTimerTests: XCTestCase {
    private final class Probe {
        var canPresent = true
        var frames = 0
    }

    private func runMainLoop(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    /// A private center: only the test's own posts reach the timer.
    private func makeFrames(_ probe: Probe, center: NotificationCenter = NotificationCenter()) -> BrightnessBoostFrameTimer {
        BrightnessBoostFrameTimer(interval: 0.01, center: center, canPresent: { probe.canPresent },
                                  present: { probe.frames += 1 })
    }

    func testFramesArriveWithoutAnyCallFromTheStrip() {
        let presented = expectation(description: "three frames")
        presented.expectedFulfillmentCount = 3
        presented.assertForOverFulfill = false
        let frames = BrightnessBoostFrameTimer(interval: 0.01, center: NotificationCenter(), canPresent: { true },
                                               present: { presented.fulfill() })
        wait(for: [presented], timeout: 2)
        frames.stop()
    }

    func testNoFramesWhileTheOverlayCannotPresent() {
        let probe = Probe()
        probe.canPresent = false
        let frames = makeFrames(probe)
        runMainLoop(for: 0.1)
        XCTAssertEqual(probe.frames, 0)
        probe.canPresent = true
        runMainLoop(for: 0.1)
        XCTAssertGreaterThan(probe.frames, 0)
        frames.stop()
    }

    /// Frames stop after `pause` and come back after `resume`.
    private func assertFramesPause(after pause: Notification.Name, until resume: Notification.Name,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let probe = Probe(), center = NotificationCenter()
        let frames = makeFrames(probe, center: center)
        center.post(name: pause, object: nil)
        runMainLoop(for: 0.1)
        XCTAssertEqual(probe.frames, 0, file: file, line: line)
        center.post(name: resume, object: nil)
        runMainLoop(for: 0.1)
        XCTAssertGreaterThan(probe.frames, 0, file: file, line: line)
        frames.stop()
    }

    func testNoFramesWhileTheDisplaysSleep() {
        // A sleeping display takes no frames, so waiting for a drawable would block the main thread.
        assertFramesPause(after: NSWorkspace.screensDidSleepNotification, until: NSWorkspace.screensDidWakeNotification)
    }

    func testNoFramesWhileTheMacSleeps() {
        // Extra stays on through system sleep.
        assertFramesPause(after: NSWorkspace.willSleepNotification, until: NSWorkspace.didWakeNotification)
    }

    func testNoFramesWhileAnotherUserSessionIsActive() {
        // Extra stays on through a session switch, while nothing shows this session's windows.
        assertFramesPause(after: NSWorkspace.sessionDidResignActiveNotification,
                          until: NSWorkspace.sessionDidBecomeActiveNotification)
    }

    func testFramesResumeOnlyWhenEveryPauseHasEnded() {
        let probe = Probe(), center = NotificationCenter()
        let frames = makeFrames(probe, center: center)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        runMainLoop(for: 0.1)
        XCTAssertEqual(probe.frames, 0, "The displays can still be asleep after the Mac wakes.")
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        runMainLoop(for: 0.1)
        XCTAssertGreaterThan(probe.frames, 0)
        frames.stop()
    }

    /// The steady timer never fires here, so only the app switch presents.
    private func makeSwitchFrames(_ probe: Probe, center: NotificationCenter) -> BrightnessBoostFrameTimer {
        BrightnessBoostFrameTimer(interval: 60, switchBurst: (count: 3, interval: 0.01), center: center,
                                  canPresent: { probe.canPresent }, present: { probe.frames += 1 })
    }

    func testAnAppSwitchPresentsAFrameAtOnce() {
        // Every ⌘Tab dimmed the boost for a moment (2026-10-19); the steady frame can be 0.2 s away.
        let probe = Probe(), center = NotificationCenter()
        let frames = makeSwitchFrames(probe, center: center)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(probe.frames, 1)
        frames.stop()
    }

    func testAnAppSwitchPresentsAShortBurst() {
        let probe = Probe(), center = NotificationCenter()
        let frames = makeSwitchFrames(probe, center: center)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        runMainLoop(for: 0.2)
        XCTAssertEqual(probe.frames, 4, "One frame at once, then the burst of three.")
        frames.stop()
    }

    func testAnAppSwitchWhilePausedPresentsNothing() {
        let probe = Probe(), center = NotificationCenter()
        let frames = makeSwitchFrames(probe, center: center)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        runMainLoop(for: 0.1)
        XCTAssertEqual(probe.frames, 0)
        frames.stop()
    }

    func testStopEndsABurst() {
        let probe = Probe(), center = NotificationCenter()
        let frames = makeSwitchFrames(probe, center: center)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        frames.stop()
        runMainLoop(for: 0.1)
        XCTAssertLessThanOrEqual(probe.frames, 1, "A closed overlay takes no burst frames.")
    }

    func testStopEndsTheFrames() {
        let probe = Probe()
        let frames = makeFrames(probe)
        runMainLoop(for: 0.1)
        frames.stop()
        let stopped = probe.frames
        runMainLoop(for: 0.1)
        XCTAssertGreaterThan(stopped, 0)
        XCTAssertEqual(probe.frames, stopped)
    }

    func testReleasingTheTimerEndsTheFrames() {
        let probe = Probe()
        var frames: BrightnessBoostFrameTimer? = makeFrames(probe)
        XCTAssertNotNil(frames)
        frames = nil
        runMainLoop(for: 0.1)
        XCTAssertEqual(probe.frames, 0)
    }

    func testThreeFramesFitInTheMeasuredHeadroomHold() {
        // WindowServer dropped a background boost 0.77 s after its last frame (logs, 2026-10-19),
        // so one late frame must not end Extra. BrightIntosh presents the same overlay at 5 fps.
        XCTAssertLessThanOrEqual(BrightnessBoostFrameTimer.interval * 3, 0.77)
    }
}
