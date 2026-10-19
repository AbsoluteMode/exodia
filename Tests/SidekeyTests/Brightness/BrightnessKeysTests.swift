import AppKit
import Combine
import CoreGraphics
import XCTest
@testable import Sidekey

/// The Mac's brightness keys arrive as system-defined aux-button events (subtype 8):
/// data1 packs the key type (2 up, 3 down), the state (0x0A down, 0x0B up) and the repeat bit.
@MainActor
final class BrightnessKeysTests: XCTestCase {
    // MARK: Reading the event

    func testReadsBrightnessUpAndDownPressesAndReleases() {
        XCTAssertEqual(BrightnessKeyEvent.parse(subtype: 8, data1: data1(key: 2, state: 0x0A), flags: []),
                       BrightnessKeyEvent(direction: .up, isDown: true, isRepeat: false, step: .normal))
        XCTAssertEqual(BrightnessKeyEvent.parse(subtype: 8, data1: data1(key: 3, state: 0x0B), flags: []),
                       BrightnessKeyEvent(direction: .down, isDown: false, isRepeat: false, step: .normal))
        XCTAssertEqual(BrightnessKeyEvent.parse(subtype: 8, data1: data1(key: 2, state: 0x0A, isRepeat: true),
                                                flags: [])?.isRepeat, true)
    }

    func testOtherSystemKeysAreLeftAlone() {
        // Sound, mute, play and the keyboard backlight keys.
        for key in [0, 1, 7, 16, 21, 22, 23] {
            XCTAssertNil(BrightnessKeyEvent.parse(subtype: 8, data1: data1(key: key, state: 0x0A), flags: []), "\(key)")
        }
        XCTAssertNil(BrightnessKeyEvent.parse(subtype: 7, data1: data1(key: 2, state: 0x0A), flags: []))
        XCTAssertNil(BrightnessKeyEvent.parse(subtype: 8, data1: data1(key: 2, state: 0x01), flags: []))
    }

    func testOptionShiftIsAFineStepAndOtherModifiersStayWithMacOS() {
        XCTAssertEqual(BrightnessKeyEvent.step(for: []), .normal)
        // Fn (function-key row) and Caps Lock do not change the key.
        XCTAssertEqual(BrightnessKeyEvent.step(for: [.maskSecondaryFn, .maskAlphaShift]), .normal)
        XCTAssertEqual(BrightnessKeyEvent.step(for: [.maskAlternate, .maskShift]), .fine)
        XCTAssertEqual(BrightnessKeyEvent.step(for: [.maskAlternate, .maskShift, .maskSecondaryFn]), .fine)
        let macOSCombinations: [CGEventFlags] = [.maskAlternate, .maskShift, .maskCommand, .maskControl,
                                                 [.maskAlternate, .maskShift, .maskCommand]]
        for flags in macOSCombinations {
            XCTAssertNil(BrightnessKeyEvent.step(for: flags), "\(flags)")
        }
        XCTAssertNil(BrightnessKeyEvent.parse(subtype: 8, data1: data1(key: 2, state: 0x0A),
                                              flags: .maskAlternate)?.step)
    }

    // MARK: Steps

    func testAStepMovesASixteenthToTheNextMark() {
        XCTAssertEqual(BrightnessKeyStep.level(after: 0.5, direction: .up, step: .normal), 0.5625)
        XCTAssertEqual(BrightnessKeyStep.level(after: 0.5, direction: .down, step: .normal), 0.4375)
        // Between marks a step lands on the next one.
        XCTAssertEqual(BrightnessKeyStep.level(after: 0.6, direction: .up, step: .normal), 0.625)
        XCTAssertEqual(BrightnessKeyStep.level(after: 0.6, direction: .down, step: .normal), 0.5625)
    }

    func testAStepNeverMovesLessThanAQuarterStep() {
        XCTAssertEqual(BrightnessKeyStep.level(after: 0.5624999, direction: .up, step: .normal), 0.625)
        XCTAssertEqual(BrightnessKeyStep.level(after: 0.5625001, direction: .up, step: .normal), 0.625)
        XCTAssertEqual(BrightnessKeyStep.level(after: 0.5625001, direction: .down, step: .normal), 0.5)
        XCTAssertEqual(BrightnessKeyStep.level(after: 0.97, direction: .up, step: .normal), 1)
    }

    func testStepsStopAtBothEnds() {
        XCTAssertEqual(BrightnessKeyStep.level(after: 1, direction: .up, step: .normal), 1)
        XCTAssertEqual(BrightnessKeyStep.level(after: 0, direction: .down, step: .normal), 0)
        XCTAssertEqual(BrightnessKeyStep.level(after: 0.02, direction: .down, step: .normal), 0)
    }

    func testAFineStepIsAQuarterOfAStep() {
        XCTAssertEqual(BrightnessKeyStep.level(after: 0.5, direction: .up, step: .fine), 0.515625)
        XCTAssertEqual(BrightnessKeyStep.level(after: 0.5, direction: .down, step: .fine), 0.484375)
    }

    // MARK: Two presses at the top

    func testTwoPressesAtTheMaximumAskForExtra() {
        var gesture = BrightnessExtraKeyGesture()
        XCTAssertFalse(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start))
        XCTAssertTrue(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start + 0.5))
        // It starts over after asking.
        XCTAssertFalse(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start + 0.8))
    }

    func testThePressThatReachesTheMaximumIsNotOneOfTheTwo() {
        var gesture = BrightnessExtraKeyGesture()
        XCTAssertFalse(gesture.register(.up, isRepeat: false, levelBefore: 0.9375, at: start))
        XCTAssertFalse(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start + 0.2))
        XCTAssertTrue(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start + 0.4))
    }

    func testHoldingTheKeyIsNotASecondPress() {
        var gesture = BrightnessExtraKeyGesture()
        XCTAssertFalse(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start))
        XCTAssertFalse(gesture.register(.up, isRepeat: true, levelBefore: 1, at: start + 0.3))
        XCTAssertFalse(gesture.register(.up, isRepeat: true, levelBefore: 1, at: start + 0.4))
        // Repeats neither count nor cancel.
        XCTAssertTrue(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start + 0.9))
    }

    func testBrightnessDownOrAPressBelowTheTopStartsOver() {
        var gesture = BrightnessExtraKeyGesture()
        XCTAssertFalse(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start))
        XCTAssertFalse(gesture.register(.down, isRepeat: false, levelBefore: 1, at: start + 0.2))
        XCTAssertFalse(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start + 0.4))
        XCTAssertFalse(gesture.register(.up, isRepeat: false, levelBefore: 0.5, at: start + 0.6))
        XCTAssertFalse(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start + 0.8))
        XCTAssertTrue(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start + 1))
    }

    func testTheSecondPressMustFollowWithinTheWindow() {
        var gesture = BrightnessExtraKeyGesture()
        XCTAssertFalse(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start))
        XCTAssertFalse(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start + 1.6))
        XCTAssertTrue(gesture.register(.up, isRepeat: false, levelBefore: 1, at: start + 3))
    }

    // MARK: Which presses Whytap keeps from macOS

    func testAKeptPressKeepsItsRepeatsAndRelease() {
        var filter = BrightnessKeyFilter()
        XCTAssertTrue(filter.shouldSwallow(key(.up), intercepting: true))
        XCTAssertTrue(filter.shouldSwallow(key(.up, isRepeat: true), intercepting: true))
        XCTAssertTrue(filter.shouldSwallow(key(.up, isDown: false), intercepting: true))
    }

    func testAPressMacOSGotStaysWithMacOS() {
        var filter = BrightnessKeyFilter()
        XCTAssertFalse(filter.shouldSwallow(key(.down), intercepting: false))
        XCTAssertFalse(filter.shouldSwallow(key(.down, isRepeat: true), intercepting: true))
        XCTAssertFalse(filter.shouldSwallow(key(.down, isDown: false), intercepting: true))
    }

    func testAPressExodiaDidNotSeeBeginStaysWithMacOS() {
        // The tap was installed while the key was held, so macOS got the press.
        var filter = BrightnessKeyFilter()
        XCTAssertFalse(filter.shouldSwallow(key(.up, isRepeat: true), intercepting: true))
        XCTAssertFalse(filter.shouldSwallow(key(.up, isRepeat: true), intercepting: true))
        XCTAssertFalse(filter.shouldSwallow(key(.up, isDown: false), intercepting: true))
        XCTAssertTrue(filter.shouldSwallow(key(.up), intercepting: true))
    }

    func testAPressHeldThroughTheHotkeyRebuildKeepsItsOwner() {
        var filter = BrightnessKeyFilter()
        XCTAssertTrue(filter.shouldSwallow(key(.up), intercepting: true))
        // The rebuild installs the next tap within milliseconds.
        filter.stopWatching(at: 10)
        filter.resumeWatching(at: 10.05)
        XCTAssertTrue(filter.shouldSwallow(key(.up, isRepeat: true), intercepting: true))
        XCTAssertTrue(filter.shouldSwallow(key(.up, isDown: false), intercepting: true))
    }

    func testAfterALongerGapThePressesInProgressFinishWithMacOS() {
        // Long enough to release the key and press it again unseen.
        var filter = BrightnessKeyFilter()
        XCTAssertTrue(filter.shouldSwallow(key(.up), intercepting: true))
        filter.stopWatching(at: 10)
        // Stopping again does not shorten the gap.
        filter.stopWatching(at: 10.45)
        filter.resumeWatching(at: 10.5)
        XCTAssertFalse(filter.shouldSwallow(key(.up, isRepeat: true), intercepting: true))
        XCTAssertFalse(filter.shouldSwallow(key(.up, isDown: false), intercepting: true))
        XCTAssertTrue(filter.shouldSwallow(key(.up), intercepting: true))
    }

    func testAfterMacOSDisablesTheTapThePressesInProgressFinishWithMacOS() {
        // Events went past the disabled tap until it was enabled again.
        var filter = BrightnessKeyFilter()
        XCTAssertTrue(filter.shouldSwallow(key(.up), intercepting: true))
        filter.forgetPresses()
        // Released unseen and pressed again with Option, which is macOS's.
        XCTAssertFalse(filter.shouldSwallow(key(.up, isRepeat: true, step: nil), intercepting: true))
        XCTAssertFalse(filter.shouldSwallow(key(.up, isDown: false, step: nil), intercepting: true))
    }

    func testAKeptPressStaysKeptWhenInterceptionEnds() {
        var filter = BrightnessKeyFilter()
        XCTAssertTrue(filter.shouldSwallow(key(.up), intercepting: true))
        XCTAssertTrue(filter.shouldSwallow(key(.up, isRepeat: true), intercepting: false))
        XCTAssertTrue(filter.shouldSwallow(key(.up, isDown: false), intercepting: false))
        XCTAssertFalse(filter.shouldSwallow(key(.up), intercepting: false))
    }

    func testModifierCombinationsAndStrayReleasesGoToMacOS() {
        var filter = BrightnessKeyFilter()
        XCTAssertFalse(filter.shouldSwallow(key(.up, step: nil), intercepting: true))
        XCTAssertFalse(filter.shouldSwallow(key(.up, isDown: false, step: nil), intercepting: true))
        XCTAssertFalse(filter.shouldSwallow(key(.down, isDown: false), intercepting: true))
    }

    func testTheTwoKeysAreTrackedSeparately() {
        var filter = BrightnessKeyFilter()
        XCTAssertTrue(filter.shouldSwallow(key(.up), intercepting: true))
        XCTAssertFalse(filter.shouldSwallow(key(.down), intercepting: false))
        XCTAssertTrue(filter.shouldSwallow(key(.up, isDown: false), intercepting: false))
        XCTAssertFalse(filter.shouldSwallow(key(.down, isDown: false), intercepting: true))
    }

    // MARK: A kept press

    func testAPressStepsTheIslandDisplayAndShowsTheStrip() {
        let f = KeyFixture(level: 0.5)
        f.press(key(.up))
        XCTAssertEqual(f.controller.level, 0.5625)
        f.clock.advance(0.1)
        f.press(key(.down))
        XCTAssertEqual(f.device.writes, [0.5625, 0.5])
        XCTAssertEqual(f.shown.count, 2)
    }

    func testPressesInARowStepFromTheLastWrittenLevel() {
        let f = KeyFixture(level: 0.5)
        f.device.appliesWrites = false
        f.press(key(.up))
        f.clock.advance(0.1)
        f.press(key(.up, isRepeat: true))
        XCTAssertEqual(f.device.writes, [0.5625, 0.625])
    }

    func testAPressStartsFromALevelChangedElsewhere() {
        let f = KeyFixture(level: 0.5)
        f.press(key(.up))
        f.clock.advance(5)
        f.device.level = 0.25
        f.press(key(.up))
        XCTAssertEqual(f.device.writes, [0.5625, 0.3125])
    }

    func testTwoPressesAtTheMaximumTurnExtraOn() {
        let f = KeyFixture(level: 1)
        f.press(key(.up))
        XCTAssertFalse(f.controller.isExtraOn)
        f.clock.advance(0.4)
        f.press(key(.up))
        XCTAssertTrue(f.controller.isExtraOn)
        XCTAssertEqual(f.device.writes, [], "The backlight is already at its maximum.")
        XCTAssertEqual(f.shown.count, 2)
    }

    func testBrightnessDownKeepsExtraOn() {
        let f = KeyFixture(level: 1)
        f.controller.refresh()
        f.controller.setExtra(true)
        f.press(key(.down))
        XCTAssertTrue(f.controller.isExtraOn)
        XCTAssertEqual(f.device.writes, [0.9375])
    }

    func testWithoutHeadroomTwoPressesOnlyShowTheStrip() {
        let f = KeyFixture(level: 1, headroom: 1)
        f.press(key(.up))
        f.press(key(.up))
        XCTAssertFalse(f.controller.isExtraOn)
        XCTAssertEqual(f.device.overlays, 0)
        XCTAssertEqual(f.shown.count, 2)
    }

    func testReleasesAndModifierRepeatsChangeNothing() {
        let f = KeyFixture(level: 0.5)
        f.press(key(.up, isDown: false))
        f.press(key(.up, isRepeat: true, step: nil))
        XCTAssertEqual(f.device.writes, [])
        XCTAssertEqual(f.shown.count, 0)
    }

    // MARK: The setting and the tap

    func testBrightnessKeysAreOffByDefault() {
        let k = KeysFixture(self)
        k.keys.start(showStrip: {})
        XCTAssertFalse(k.keys.isEnabled)
        XCTAssertFalse(k.keys.isListening)
        XCTAssertEqual(k.tap.starts, 0)
    }

    func testTurningThemOnInstallsTheTapAndIsRemembered() {
        let k = KeysFixture(self)
        k.keys.start(showStrip: {})
        k.keys.setEnabled(true)
        XCTAssertTrue(k.keys.isEnabled)
        XCTAssertTrue(k.keys.isListening)
        XCTAssertEqual(k.tap.intercepting, true)
        XCTAssertTrue(k.defaults.bool(forKey: BrightnessKeys.defaultsKey))

        let relaunched = k.makeKeys()
        relaunched.start(showStrip: {})
        XCTAssertTrue(relaunched.isListening)
    }

    func testStartingAgainKeepsTheInstalledTap() {
        let k = KeysFixture(self)
        k.keys.start(showStrip: {})
        k.keys.setEnabled(true)
        k.keys.start(showStrip: {})
        XCTAssertEqual(k.tap.starts, 1)
    }

    func testStartingAgainBetweenTheTwoPressesStillTurnsExtraOn() {
        // Drop's permission repair starts the keys every second while Drop is not installed.
        let k = KeysFixture(self)
        k.device.level = 1
        k.keys.start(showStrip: {})
        k.keys.setEnabled(true)
        k.tap.deliver?(key(.up), start)
        k.keys.start(showStrip: {})
        k.tap.deliver?(key(.up), start)
        XCTAssertTrue(k.controller.isExtraOn)
    }

    func testTheTwoPressesCountWhenTheyHappenedNotWhenTheyAreHandled() {
        // A busy main thread hands presses 2 s apart over late and together.
        let k = KeysFixture(self)
        k.device.level = 1
        k.keys.start(showStrip: {})
        k.keys.setEnabled(true)
        k.tap.deliver?(key(.up), start)
        k.tap.deliver?(key(.up), start + 2)
        XCTAssertFalse(k.controller.isExtraOn)
    }

    func testTurningThemOffRemovesTheTap() {
        let k = KeysFixture(self)
        k.keys.start(showStrip: {})
        k.keys.setEnabled(true)
        k.keys.setEnabled(false)
        XCTAssertEqual(k.tap.stops, 1)
        XCTAssertFalse(k.keys.isListening)
        XCTAssertFalse(k.defaults.bool(forKey: BrightnessKeys.defaultsKey))
    }

    func testKeysStayWithMacOSWhileHoverIsHiddenOrTheDisplayIsNotAdjustable() {
        let k = KeysFixture(self)
        k.keys.start(showStrip: {})
        k.keys.setEnabled(true)
        k.hoverHidden.send(true)
        XCTAssertEqual(k.tap.intercepting, false)
        k.hoverHidden.send(false)
        XCTAssertEqual(k.tap.intercepting, true)
        k.device.level = nil
        k.controller.refresh()
        XCTAssertEqual(k.tap.intercepting, false)
    }

    func testARefusedTapIsRetriedOnTheNextStart() {
        let k = KeysFixture(self)
        k.tap.accepts = false
        k.keys.start(showStrip: {})
        k.keys.setEnabled(true)
        XCTAssertTrue(k.keys.isEnabled)
        XCTAssertFalse(k.keys.isListening)

        k.tap.accepts = true
        k.keys.start(showStrip: {})
        XCTAssertTrue(k.keys.isListening)
    }

    func testOpeningSettingsRetriesOnlyARefusedTap() {
        let k = KeysFixture(self)
        k.tap.accepts = false
        k.keys.start(showStrip: {})
        k.keys.setEnabled(true)
        k.tap.accepts = true
        k.keys.retryIfNeeded()
        XCTAssertTrue(k.keys.isListening)
        k.keys.retryIfNeeded()
        XCTAssertEqual(k.tap.starts, 2)

        let off = KeysFixture(self)
        off.keys.start(showStrip: {})
        off.keys.retryIfNeeded()
        XCTAssertEqual(off.tap.starts, 0)
    }

    func testATapMacOSStopsStopsListening() {
        let k = KeysFixture(self)
        k.keys.start(showStrip: {})
        k.keys.setEnabled(true)
        k.tap.onFailure?()
        XCTAssertFalse(k.keys.isListening)
        XCTAssertTrue(k.keys.isEnabled)
    }

    func testAKeptPressReachesTheDisplayAndTheStrip() {
        let k = KeysFixture(self)
        let shown = Counter()
        k.keys.start(showStrip: { shown.count += 1 })
        k.keys.setEnabled(true)
        k.tap.deliver?(key(.up), start)
        XCTAssertEqual(k.device.writes, [0.5625])
        XCTAssertEqual(shown.count, 1)
    }

    func testQuittingRemovesTheTapButKeepsTheSetting() {
        let k = KeysFixture(self)
        k.keys.start(showStrip: {})
        k.keys.setEnabled(true)
        k.keys.stop()
        XCTAssertEqual(k.tap.stops, 1)
        XCTAssertFalse(k.keys.isListening)
        XCTAssertTrue(k.defaults.bool(forKey: BrightnessKeys.defaultsKey))
    }

    // MARK: The island

    func testAKeyGlanceTakesNoKeyboardFocus() {
        XCTAssertFalse(IslandView.panelWantsKeyboardFocus(.brightness, searchFocused: false, glance: true))
        XCTAssertTrue(IslandView.panelWantsKeyboardFocus(.brightness, searchFocused: false, glance: false))
        XCTAssertFalse(IslandView.panelWantsKeyboardFocus(.controls, searchFocused: false, glance: false))
        XCTAssertTrue(IslandView.panelWantsKeyboardFocus(.controls, searchFocused: true, glance: true))
    }

    func testAKeyGlanceReplacesOnlyToolsOrPanelsThePointerIsNotOn() {
        XCTAssertTrue(IslandView.brightnessGlanceMayOpen(over: .controls, hovering: false, searchFocused: false))
        XCTAssertTrue(IslandView.brightnessGlanceMayOpen(over: .history, hovering: false, searchFocused: false))
        XCTAssertTrue(IslandView.brightnessGlanceMayOpen(over: .controls, hovering: true, searchFocused: false))
        XCTAssertTrue(IslandView.brightnessGlanceMayOpen(over: .brightness, hovering: true, searchFocused: false))
        XCTAssertFalse(IslandView.brightnessGlanceMayOpen(over: .history, hovering: true, searchFocused: false))
        XCTAssertFalse(IslandView.brightnessGlanceMayOpen(over: .controls, hovering: true, searchFocused: true))
    }

    func testAKeyGlanceClosesSoonerThanAHotkeyPanel() {
        XCTAssertEqual(IslandView.programmaticCollapseDelay(glance: true), 2)
        XCTAssertEqual(IslandView.programmaticCollapseDelay(glance: false), 4)
    }

    func testThePointerReachingAKeyGlanceFromBelowHoldsIt() {
        // The glance opened without the pointer crossing the pill; reaching the strip still holds it.
        XCTAssertTrue(IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: true,
                                                  wasExpanded: false, glance: true))
        // Otherwise only the pill opens a closed drawer, so its fading band cannot reopen it.
        XCTAssertFalse(IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: true,
                                                   wasExpanded: false, glance: false))
        XCTAssertTrue(IslandView.mouseHoldsDrawer(pillHovering: true, panelHovering: false,
                                                  wasExpanded: false, glance: false))
        XCTAssertFalse(IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: false,
                                                   wasExpanded: true, glance: true))
    }

    // MARK: Helpers

    private let start = Date(timeIntervalSince1970: 1_000)

    private func data1(key: Int, state: Int, isRepeat: Bool = false) -> Int {
        key << 16 | state << 8 | (isRepeat ? 1 : 0)
    }

    private func key(_ direction: BrightnessKeyEvent.Direction, isDown: Bool = true, isRepeat: Bool = false,
                     step: BrightnessKeyEvent.Step? = .normal) -> BrightnessKeyEvent {
        BrightnessKeyEvent(direction: direction, isDown: isDown, isRepeat: isRepeat, step: step)
    }
}

private final class Counter {
    var count = 0
}

private final class KeyClock {
    var now = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

/// Display 1 with fake hardware; no real backlight or overlay.
@MainActor
private final class KeyFixture {
    let device: KeyBrightnessDevice
    let clock = KeyClock()
    let shown = Counter()
    let controller: ScreenBrightnessController
    let handler: BrightnessKeyHandler

    init(level: Double, headroom: Double = 16) {
        let clock = clock, shown = shown
        device = KeyBrightnessDevice(level: level, headroom: headroom)
        controller = ScreenBrightnessController(device: device, selectedDisplayID: { 1 }, observeSystem: false,
                                                extraAllowed: { true }, now: { clock.now })
        handler = BrightnessKeyHandler(controller: controller, showStrip: { shown.count += 1 })
    }

    func press(_ event: BrightnessKeyEvent) {
        handler.handle(event, at: clock.now)
    }
}

/// The setting with a private defaults suite, a fake tap and a fake hover-hidden switch.
@MainActor
private final class KeysFixture {
    let defaults: UserDefaults
    let device = KeyBrightnessDevice(level: 0.5, headroom: 16)
    let tap = FakeKeyTap()
    let hoverHidden = CurrentValueSubject<Bool, Never>(false)
    let controller: ScreenBrightnessController
    private(set) lazy var keys = makeKeys()

    init(_ test: XCTestCase) {
        let suite = "BrightnessKeysTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        test.addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        controller = ScreenBrightnessController(device: device, selectedDisplayID: { 1 }, observeSystem: false,
                                                extraAllowed: { true })
    }

    func makeKeys() -> BrightnessKeys {
        BrightnessKeys(defaults: defaults, controller: controller, tap: tap,
                       hoverHidden: hoverHidden.eraseToAnyPublisher())
    }
}

/// Also stands in for the tap in the Settings pane tests.
@MainActor
final class FakeKeyTap: BrightnessKeyTapping {
    var accepts = true
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var intercepting: Bool?
    private(set) var deliver: (@MainActor (BrightnessKeyEvent, Date) -> Void)?
    private(set) var onFailure: (@MainActor () -> Void)?

    func start(deliver: @escaping @MainActor (BrightnessKeyEvent, Date) -> Void,
               onFailure: @escaping @MainActor () -> Void) -> Bool {
        starts += 1
        guard accepts else { return false }
        self.deliver = deliver
        self.onFailure = onFailure
        return true
    }

    func stop() {
        stops += 1
        deliver = nil
        onFailure = nil
    }

    func setIntercepting(_ intercepting: Bool) {
        self.intercepting = intercepting
    }
}

@MainActor
private final class KeyBrightnessDevice: ScreenBrightnessDevice {
    var level: Double?
    let headroom: Double
    var appliesWrites = true
    private(set) var writes: [Double] = []
    private(set) var overlays = 0

    init(level: Double?, headroom: Double) {
        self.level = level
        self.headroom = headroom
    }

    func displays() -> [ScreenBrightnessDisplay] { [ScreenBrightnessDisplay(id: 1, potentialHeadroom: headroom)] }

    func read(_ id: CGDirectDisplayID) -> Double? { level }

    func write(_ next: Double, to id: CGDirectDisplayID) -> Bool {
        guard level != nil else { return false }
        writes.append(next)
        if appliesWrites { level = next }
        return true
    }

    func makeOverlay(for id: CGDirectDisplayID, multiplier: Double,
                     onFailure: @escaping () -> Void) -> BrightnessOverlay? {
        overlays += 1
        return KeyNoOverlay()
    }
}

@MainActor
private final class KeyNoOverlay: BrightnessOverlay {
    func update(multiplier: Double) {}
    func close() {}
}
