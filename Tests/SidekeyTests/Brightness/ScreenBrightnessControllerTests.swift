import AppKit
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

    func testExtraStartsTheBoostWithoutTouchingTheBacklight() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()

        controller.setExtra(true)

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.4, "Extra adds to the current level; it does not raise it.")
        XCTAssertNil(controller.notice)
        XCTAssertEqual(device.events, ["boost 1"])
    }

    func testSwitchingExtraOffLeavesTheBacklightAsItIs() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()
        controller.setLevel(0.7)

        controller.setExtra(false)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.7)
        XCTAssertEqual(device.boosts.first?.isClosed, true)
        XCTAssertEqual(device.events, ["boost 1", "write 1 0.7"])
    }

    func testTheSliderKeepsExtraAtAnyLevel() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        controller.setLevel(0.2)
        controller.setLevel(1)

        XCTAssertTrue(controller.isExtraOn, "Only the switch ends Extra, as with the Mac's own brightness keys.")
        XCTAssertEqual(controller.level, 1)
        XCTAssertEqual(device.boosts.first?.isClosed, false)
        XCTAssertEqual(device.events, ["boost 1", "write 1 0.2", "write 1 1.0"])
    }

    func testOutsideBacklightChangesKeepExtra() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        // Automatic brightness, idle dimming or the brightness keys.
        device.hardware[1] = 0.5
        controller.refresh()

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.5)
        XCTAssertEqual(device.boosts.first?.isClosed, false)
        XCTAssertEqual(device.boosts.first?.refreshes, 1, "The boost follows the display on every refresh.")
        XCTAssertEqual(device.events, ["boost 1"])
    }

    func testSleepAndASessionSwitchKeepExtra() {
        let f = Fixture()
        f.observesSystem = true
        let device = f.device, controller = f.controllerWithExtra()
        device.hardware[1] = 0.6

        f.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        f.workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        f.workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        f.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertEqual(controller.level, 0.6, "The wake notification reached the controller.")
        XCTAssertTrue(controller.isExtraOn, "Extra never resumes by itself, so sleep must not end it.")
        XCTAssertEqual(device.boosts.first?.isClosed, false)
        XCTAssertEqual(device.events, ["boost 1"])
        controller.shutdown()
    }

    func testClosingTheStripKeepsExtraAndShutdownEndsIt() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        controller.endInteraction()
        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(device.boosts.first?.isClosed, false)

        controller.shutdown()
        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(device.boosts.first?.isClosed, true)
        XCTAssertEqual(device.events, ["boost 1"])
    }

    func testDisplayChangeEndsExtraAndReadsTheNewDisplayImmediately() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.connected.append(ScreenBrightnessDisplay(id: 2, potentialHeadroom: 1))
        device.hardware[2] = 0.7
        controller.beginInteraction()
        controller.setLevel(0.8)
        controller.setExtra(true)

        // Within the settle window of the slider write to display 1.
        f.selected.id = 2
        controller.refresh()

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(device.boosts.first?.isClosed, true)
        XCTAssertEqual(controller.display?.id, 2)
        XCTAssertFalse(controller.supportsExtra)
        XCTAssertEqual(controller.level, 0.7, "A write to the old display must not hold the new display's reading.")
        XCTAssertEqual(device.events, ["write 1 0.8", "boost 1"], "Ending Extra writes no backlight.")
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
        XCTAssertEqual(device.events, ["boost 1"])
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
        f.policy.extraAllowed = false
        controller.thermalStateDidChange()

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.coolingNotice)
        XCTAssertEqual(device.events, ["boost 1"])
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
        XCTAssertFalse(controller.supportsExtra, "No switch next to a slider that cannot work.")
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

    func testBoostFailureLeavesExtraOffWithANotice() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.canCreateBoost = false
        controller.beginInteraction()

        controller.setExtra(true)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.4)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.extraUnavailableNotice)
        XCTAssertEqual(device.events, ["boost-failed 1"])
    }

    func testAnUnavailableBoostEndsExtraWithANotice() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        device.ends[0](.unavailable)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.extraUnavailableNotice)
        XCTAssertEqual(device.boosts.first?.isClosed, true)
        XCTAssertEqual(device.events, ["boost 1"])
    }

    func testAnotherAppAdjustingTheDisplayEndsExtraWithItsNotice() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        device.ends[0](.otherApp)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.otherAppNotice)
        XCTAssertEqual(device.boosts.first?.isClosed, true)
    }

    func testALateEndFromAClosedBoostKeepsTheNewerExtra() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()
        controller.setExtra(false)
        controller.setExtra(true)

        device.ends[0](.unavailable)

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(device.boosts.count, 2)
        XCTAssertEqual(device.boosts.last?.isClosed, false)
    }

    // MARK: The battery estimate's display load

    func testTheBuiltInDisplayLoadIsItsLevelSquaredWithoutWrites() {
        let f = Fixture(), device = f.device
        device.connected = [ScreenBrightnessDisplay(id: 1, potentialHeadroom: 16, isBuiltIn: true)]

        XCTAssertEqual(f.controller.builtInDisplayLoad() ?? -1, 0.16, accuracy: 0.0001)
        XCTAssertEqual(device.events, [])
    }

    func testExtraOnTheBuiltInDisplayRaisesItsLoad() {
        let f = Fixture(), device = f.device
        device.connected = [ScreenBrightnessDisplay(id: 1, potentialHeadroom: 16, isBuiltIn: true)]
        let controller = f.controllerWithExtra()

        XCTAssertEqual(controller.builtInDisplayLoad() ?? -1, 0.16 * ScreenBrightnessScale.extraLight,
                       accuracy: 0.0001)
    }

    func testExtraOnAnExternalDisplayLeavesTheBuiltInLoad() {
        let f = Fixture(), device = f.device
        device.connected.append(ScreenBrightnessDisplay(id: 2, potentialHeadroom: 16, isBuiltIn: true))
        device.hardware[2] = 0.5
        let controller = f.controllerWithExtra()

        XCTAssertEqual(controller.display?.id, 1)
        XCTAssertEqual(controller.builtInDisplayLoad() ?? -1, 0.25, accuracy: 0.0001)
    }

    func testWithoutABuiltInDisplayItsLoadIsZero() {
        // A closed lid leaves only external displays.
        XCTAssertEqual(Fixture().controller.builtInDisplayLoad(), 0)
    }

    func testAnUnreadableBuiltInDisplayHasNoLoad() {
        let f = Fixture(), device = f.device
        device.connected = [ScreenBrightnessDisplay(id: 1, potentialHeadroom: 16, isBuiltIn: true)]
        device.hardware = [:]

        XCTAssertNil(f.controller.builtInDisplayLoad())
    }

    func testTheLoadFollowsTheSliderWhileTheReadingSettles() {
        let f = Fixture(), device = f.device
        device.connected = [ScreenBrightnessDisplay(id: 1, potentialHeadroom: 16, isBuiltIn: true)]
        device.applyWrites = false
        let controller = f.controller
        controller.beginInteraction()
        defer { controller.endInteraction() }

        controller.setLevel(0.8)
        XCTAssertEqual(controller.builtInDisplayLoad() ?? -1, 0.64, accuracy: 0.0001)

        f.clock.advance(ScreenBrightnessController.writeSettleInterval)
        XCTAssertEqual(controller.builtInDisplayLoad() ?? -1, 0.16, accuracy: 0.0001,
                       "Then the hardware reading wins.")
    }

    // MARK: Scale

    func testDisplayLoadIsTheLevelsLight() {
        XCTAssertEqual(ScreenBrightnessScale.displayLoad(level: 0.5, isExtraOn: false), 0.25)
        XCTAssertEqual(ScreenBrightnessScale.displayLoad(level: 2, isExtraOn: false), 1)
        // Extra's 1.45 table factor raises white by sRGB's curve.
        XCTAssertEqual(ScreenBrightnessScale.extraLight, 2.3457, accuracy: 0.0001)
        XCTAssertEqual(ScreenBrightnessScale.displayLoad(level: 1, isExtraOn: true), ScreenBrightnessScale.extraLight)
    }

    func testScaleClampsLevels() {
        XCTAssertEqual(ScreenBrightnessScale.clampedLevel(0.3), 0.3)
        XCTAssertEqual(ScreenBrightnessScale.clampedLevel(-1), 0)
        XCTAssertEqual(ScreenBrightnessScale.clampedLevel(2), 1)
        XCTAssertEqual(ScreenBrightnessScale.clampedLevel(.nan), 0)

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
    /// With `observesSystem`, notifications reach the controller only from these private centers.
    let center = NotificationCenter()
    let workspace = NotificationCenter()
    var observesSystem = false

    lazy var controller: ScreenBrightnessController = {
        let clock = clock, selected = selected, policy = policy
        return ScreenBrightnessController(device: device, selectedDisplayID: { selected.id },
                                          observeSystem: observesSystem, center: center, workspaceCenter: workspace,
                                          extraAllowed: { policy.extraAllowed }, now: { clock.now })
    }()

    /// The strip is open with Extra on.
    func controllerWithExtra() -> ScreenBrightnessController {
        controller.beginInteraction()
        controller.setExtra(true)
        return controller
    }
}

@MainActor
private final class FakeBrightnessDevice: ScreenBrightnessDevice {
    var connected = [ScreenBrightnessDisplay(id: 1, potentialHeadroom: 16)]
    var hardware: [CGDirectDisplayID: Double] = [1: 0.4]
    var canWrite = true
    var canCreateBoost = true
    /// A real panel can report the previous level for a moment after a write.
    var applyWrites = true
    private(set) var events: [String] = []
    private(set) var boosts: [FakeBrightnessBoost] = []
    private(set) var ends: [(BrightnessBoostEnd) -> Void] = []

    func displays() -> [ScreenBrightnessDisplay] { connected }

    func read(_ id: CGDirectDisplayID) -> Double? { hardware[id] }

    func write(_ level: Double, to id: CGDirectDisplayID) -> Bool {
        guard canWrite, hardware[id] != nil else {
            events.append("write-failed \(id) \(level)")
            return false
        }
        events.append("write \(id) \(level)")
        if applyWrites { hardware[id] = level }
        return true
    }

    func makeBoost(for id: CGDirectDisplayID, onEnd: @escaping (BrightnessBoostEnd) -> Void) -> BrightnessBoost? {
        guard canCreateBoost else {
            events.append("boost-failed \(id)")
            return nil
        }
        events.append("boost \(id)")
        let boost = FakeBrightnessBoost()
        boosts.append(boost)
        ends.append(onEnd)
        return boost
    }
}

@MainActor
private final class FakeBrightnessBoost: BrightnessBoost {
    private(set) var refreshes = 0
    private(set) var isClosed = false

    func refresh() { refreshes += 1 }
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
