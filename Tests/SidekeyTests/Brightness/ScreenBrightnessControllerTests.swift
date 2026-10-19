import Combine
import CoreGraphics
import XCTest
@testable import Sidekey

@MainActor
final class ScreenBrightnessControllerTests: XCTestCase {
    // MARK: Reading and the slider

    func testOpeningTheStripOnlyReadsTheLevel() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()

        XCTAssertEqual(controller.level, 0.4)
        XCTAssertTrue(controller.isAvailable)
        XCTAssertTrue(controller.supportsExtra)
        XCTAssertFalse(controller.isExtraOn)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(device.events, [])
    }

    func testSliderWritesTheClampedLevel() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()

        controller.setLevel(0.7)
        XCTAssertEqual(controller.level, 0.7)
        controller.setLevel(1.4)
        XCTAssertEqual(controller.level, 1)
        controller.setLevel(-1)
        XCTAssertEqual(controller.level, 0)
        XCTAssertEqual(device.events, ["write 1 0.7", "write 1 1.0", "write 1 0.0"])
    }

    func testReadsSettleBrieflyAfterAWrite() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.applyWrites = false
        controller.beginInteraction()

        controller.setLevel(0.8)
        controller.refresh()
        XCTAssertEqual(controller.level, 0.8, "A read right after a write can still report the old level.")

        f.clock.advance(ScreenBrightnessController.writeSettleInterval + 0.1)
        controller.refresh()
        XCTAssertEqual(controller.level, 0.4, "After the settle window the hardware reading wins.")
    }

    func testOutsideChangesAreFollowedWhileTheStripIsOpen() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()

        device.hardware[1] = 0.25
        controller.refresh()
        XCTAssertEqual(controller.level, 0.25)
        XCTAssertEqual(device.events, [])
    }

    func testUnchangedRefreshPublishesNothing() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()
        var announcements = 0
        let subscription = controller.objectWillChange.sink { announcements += 1 }
        defer { subscription.cancel() }

        controller.refresh()
        controller.refresh()
        XCTAssertEqual(announcements, 0, "The strip polls twice a second; unchanged values must not redraw it.")

        device.hardware[1] = 0.6
        controller.refresh()
        XCTAssertGreaterThan(announcements, 0)
    }

    func testPollingRunsOnlyWhileAStripIsVisible() {
        let f = Fixture(), controller = f.controller
        controller.refresh()
        XCTAssertFalse(controller.isPolling, "The capsule status reads once and never polls.")

        controller.beginInteraction()
        controller.beginInteraction()
        XCTAssertTrue(controller.isPolling)
        controller.endInteraction()
        XCTAssertTrue(controller.isPolling)
        controller.endInteraction()
        XCTAssertFalse(controller.isPolling)

        controller.beginInteraction()
        controller.setExtra(true)
        controller.endInteraction()
        XCTAssertTrue(controller.isExtraOn)
        XCTAssertFalse(controller.isPolling, "Extra alone does not keep a timer running.")
        controller.shutdown()
    }

    // MARK: Extra

    func testExtraRaisesTheBacklightAndAddsTheMultiplier() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()

        controller.setExtra(true)

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(controller.level, 1)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(device.events, ["write 1 1.0", "overlay 1"])
        XCTAssertEqual(device.overlays.first?.multipliers, [2])
    }

    func testSwitchingExtraOffRestoresTheEarlierLevel() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        controller.setExtra(false)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.4)
        XCTAssertEqual(device.overlays.first?.isClosed, true)
        XCTAssertEqual(device.events.last, "write 1 0.4")
    }

    func testExtraRightAfterTheSliderReturnsToTheSliderLevel() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.applyWrites = false
        controller.beginInteraction()
        controller.setLevel(0.8)

        // Within the settle window the panel still reports the earlier 40%.
        controller.setExtra(true)
        f.clock.advance(1)
        controller.setExtra(false)

        XCTAssertEqual(controller.level, 0.8)
        XCTAssertEqual(device.events, ["write 1 0.8", "write 1 1.0", "overlay 1", "write 1 0.8"])
    }

    func testSliderBelowTheMaximumEndsExtraAtTheNewLevel() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        controller.setLevel(0.6)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.6)
        XCTAssertEqual(device.overlays.first?.isClosed, true)
        XCTAssertEqual(device.events, ["write 1 1.0", "overlay 1", "write 1 0.6"],
                       "The user's new level replaces the earlier one; it is not restored first.")
    }

    func testSliderAtTheMaximumKeepsExtraAndRaisesALoweredBacklight() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()
        device.hardware[1] = 0.8
        controller.refresh()
        XCTAssertEqual(controller.level, 0.8)

        controller.setLevel(0.995)

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(controller.level, 1)
        XCTAssertEqual(device.overlays.first?.isClosed, false)
        XCTAssertEqual(device.events.last, "write 1 1.0")
    }

    func testOutsideBacklightChangesKeepExtra() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        // Automatic brightness, idle dimming or the brightness keys.
        device.hardware[1] = 0.5
        controller.refresh()

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.5)
        XCTAssertEqual(device.overlays.first?.isClosed, false)
        XCTAssertEqual(device.overlays.first?.multipliers, [2, 2])
        XCTAssertEqual(device.events, ["write 1 1.0", "overlay 1"])
    }

    func testClosingTheStripKeepsExtraAndShutdownEndsIt() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        controller.endInteraction()
        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(device.overlays.first?.isClosed, false)

        controller.shutdown()
        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(device.overlays.first?.isClosed, true)
        XCTAssertEqual(device.events.last, "write 1 0.4")
    }

    func testDisplayChangeRestoresTheOldDisplayAndReadsTheNewOneImmediately() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.connected.append(ScreenBrightnessDisplay(id: 2, potentialHeadroom: 1))
        device.hardware[2] = 0.7
        controller.beginInteraction()
        controller.setExtra(true)

        // Within the settle window of the Extra write to display 1.
        f.selected.id = 2
        controller.refresh()

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(device.overlays.first?.isClosed, true)
        XCTAssertEqual(controller.display?.id, 2)
        XCTAssertFalse(controller.supportsExtra)
        XCTAssertEqual(controller.level, 0.7, "A write to the old display must not hold the new display's reading.")
        XCTAssertEqual(device.events, ["write 1 1.0", "overlay 1", "write 1 0.4"])
    }

    func testDisplayWithoutHeadroomHasNoExtra() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.connected = [ScreenBrightnessDisplay(id: 1, potentialHeadroom: 1)]
        controller.beginInteraction()

        controller.setExtra(true)

        XCTAssertFalse(controller.supportsExtra)
        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(device.events, [])
    }

    func testThermalPressureBlocksExtraWithoutWrites() {
        let f = Fixture(), device = f.device, controller = f.controller
        f.policy.extraAllowed = false
        controller.beginInteraction()

        controller.setExtra(true)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.coolingNotice)
        XCTAssertEqual(device.events, [])
    }

    func testStopExtraWithANoticeKeepsTheNotice() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        controller.stopExtra(notice: ScreenBrightnessController.coolingNotice)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.coolingNotice)
        XCTAssertEqual(device.events.last, "write 1 0.4")
    }

    func testCoolingPausesOnlyAnActiveExtra() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()
        f.policy.extraAllowed = false
        controller.thermalStateDidChange()
        XCTAssertNil(controller.notice, "Nothing is paused while Extra is off.")
        XCTAssertEqual(device.events, [])

        f.policy.extraAllowed = true
        controller.setExtra(true)
        f.clock.advance(1)
        f.policy.extraAllowed = false
        controller.thermalStateDidChange()

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.coolingNotice)
        XCTAssertEqual(device.events, ["write 1 1.0", "overlay 1", "write 1 0.4"])
        XCTAssertEqual(controller.level, 0.4)
    }

    // MARK: Failures

    func testUnreadableDisplayIsUnavailableAndNeverWritten() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.hardware = [:]
        controller.beginInteraction()

        controller.setLevel(0.5)
        controller.setExtra(true)

        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.supportsExtra, "No switch that could never turn on.")
        XCTAssertEqual(controller.level, 0)
        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(device.events, [])
    }

    func testNoDisplaysIsUnavailable() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.connected = []
        controller.beginInteraction()

        XCTAssertNil(controller.display)
        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.supportsExtra)
    }

    func testFailedWriteShowsANoticeUntilAWriteSucceeds() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()

        device.canWrite = false
        controller.setLevel(0.7)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.writeFailedNotice)
        XCTAssertEqual(controller.level, 0.4)

        device.canWrite = true
        controller.setLevel(0.6)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(controller.level, 0.6)
    }

    func testFailedExtraWriteShowsANoticeWithoutAnOverlay() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()
        device.canWrite = false

        controller.setExtra(true)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.writeFailedNotice)
        XCTAssertTrue(device.overlays.isEmpty)
    }

    func testOverlayFailureRestoresTheEarlierLevel() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.canCreateOverlay = false
        controller.beginInteraction()

        controller.setExtra(true)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.4)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.extraUnavailableNotice)
        XCTAssertEqual(device.events, ["write 1 1.0", "overlay-failed 1", "write 1 0.4"])
    }

    func testAFailedRollbackShowsTheMaximumTheBacklightKept() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.canCreateOverlay = false
        device.nextWrites = [true, false]
        controller.beginInteraction()

        controller.setExtra(true)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.level, 1)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.extraUnavailableNotice)
        XCTAssertEqual(device.events, ["write 1 1.0", "overlay-failed 1", "write-failed 1 0.4"])
    }

    func testAFailedRestoreAfterExtraSaysSo() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()
        device.canWrite = false

        controller.setExtra(false)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.writeFailedNotice)
        XCTAssertEqual(controller.level, 1)
        XCTAssertEqual(device.events.last, "write-failed 1 0.4")
    }

    func testRenderFailureEndsExtraWithANotice() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        device.failures[0]()

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.extraUnavailableNotice)
        XCTAssertEqual(device.overlays.first?.isClosed, true)
        XCTAssertEqual(device.events.last, "write 1 0.4")
    }

    func testLateFailureFromAClosedOverlayKeepsTheNewerExtra() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()
        controller.setExtra(false)
        controller.setExtra(true)

        device.failures[0]()

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(device.overlays.count, 2)
        XCTAssertEqual(device.overlays.last?.isClosed, false)
    }

    // MARK: Scale

    func testScaleClampsLevelsAndMultipliers() {
        XCTAssertEqual(ScreenBrightnessScale.clampedLevel(0.3), 0.3)
        XCTAssertEqual(ScreenBrightnessScale.clampedLevel(-1), 0)
        XCTAssertEqual(ScreenBrightnessScale.clampedLevel(2), 1)
        XCTAssertEqual(ScreenBrightnessScale.clampedLevel(.nan), 0)

        XCTAssertEqual(ScreenBrightnessScale.extraMultiplier(potentialHeadroom: 16), 2)
        XCTAssertEqual(ScreenBrightnessScale.extraMultiplier(potentialHeadroom: 1.6), 1.6)
        XCTAssertEqual(ScreenBrightnessScale.extraMultiplier(potentialHeadroom: 0.5), 1)
        XCTAssertEqual(ScreenBrightnessScale.extraMultiplier(potentialHeadroom: .nan), 1)

        XCTAssertFalse(ScreenBrightnessDisplay(id: 1, potentialHeadroom: 1).supportsExtra)
        XCTAssertFalse(ScreenBrightnessDisplay(id: 1, potentialHeadroom: 1.005).supportsExtra)
        XCTAssertTrue(ScreenBrightnessDisplay(id: 1, potentialHeadroom: 1.6).supportsExtra)
    }
}

/// Display 1 at 40% with XDR headroom; display selection, clock and thermal policy are adjustable.
@MainActor
private final class Fixture {
    let device = FakeBrightnessDevice()
    let clock = TestClock()
    let selected = SelectedDisplay()
    let policy = ExtraPolicy()

    lazy var controller: ScreenBrightnessController = {
        let clock = clock, selected = selected, policy = policy
        return ScreenBrightnessController(device: device, selectedDisplayID: { selected.id }, observeSystem: false,
                                          extraAllowed: { policy.extraAllowed }, now: { clock.now })
    }()

    /// The strip is open with Extra on; the clock is past the settle window.
    func controllerWithExtra() -> ScreenBrightnessController {
        controller.beginInteraction()
        controller.setExtra(true)
        clock.advance(1)
        return controller
    }
}

@MainActor
private final class FakeBrightnessDevice: ScreenBrightnessDevice {
    var connected = [ScreenBrightnessDisplay(id: 1, potentialHeadroom: 16)]
    var hardware: [CGDirectDisplayID: Double] = [1: 0.4]
    var canWrite = true
    /// Results of the next writes, in order; after them `canWrite` decides.
    var nextWrites: [Bool] = []
    var canCreateOverlay = true
    /// A real panel can report the previous level for a moment after a write.
    var applyWrites = true
    private(set) var events: [String] = []
    private(set) var overlays: [FakeBrightnessOverlay] = []
    private(set) var failures: [() -> Void] = []

    func displays() -> [ScreenBrightnessDisplay] { connected }

    func read(_ id: CGDirectDisplayID) -> Double? { hardware[id] }

    func write(_ level: Double, to id: CGDirectDisplayID) -> Bool {
        let succeeds = nextWrites.isEmpty ? canWrite : nextWrites.removeFirst()
        guard succeeds, hardware[id] != nil else {
            events.append("write-failed \(id) \(level)")
            return false
        }
        events.append("write \(id) \(level)")
        if applyWrites { hardware[id] = level }
        return true
    }

    func makeOverlay(for id: CGDirectDisplayID, multiplier: Double,
                     onFailure: @escaping () -> Void) -> BrightnessOverlay? {
        guard canCreateOverlay else {
            events.append("overlay-failed \(id)")
            return nil
        }
        events.append("overlay \(id)")
        let overlay = FakeBrightnessOverlay()
        overlays.append(overlay)
        failures.append(onFailure)
        return overlay
    }
}

@MainActor
private final class FakeBrightnessOverlay: BrightnessOverlay {
    private(set) var multipliers: [Double] = []
    private(set) var isClosed = false

    func update(multiplier: Double) { multipliers.append(multiplier) }
    func close() { isClosed = true }
}

private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

private final class SelectedDisplay {
    var id: CGDirectDisplayID? = 1
}

private final class ExtraPolicy {
    var extraAllowed = true
}
