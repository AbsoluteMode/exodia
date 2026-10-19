import Combine
import XCTest
@testable import Sidekey

private extension BatteryRuntimeEstimator {
    /// One reading as the monitor takes it: the display's light, the battery, then the status.
    mutating func add(_ snapshot: BatterySnapshot, displayLoad: Double?, at date: Date) -> BatteryRuntimeStatus {
        noteDisplayLoad(displayLoad, at: date)
        record(snapshot, at: date)
        return status(for: snapshot, at: date)
    }
}

final class BatteryRuntimeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)

    private func snapshot(percent: Int = 84, onAC: Bool = false, charging: Bool = false,
                          systemMinutes: Int? = nil, wattHours: Double? = 40,
                          loadSum: Double? = nil, loadCount: Double? = nil,
                          instantWatts: Double? = nil) -> BatterySnapshot {
        BatterySnapshot(percent: percent, isOnAC: onAC, isCharging: charging,
                        systemMinutesToEmpty: systemMinutes, remainingWattHours: wattHours,
                        loadSum: loadSum, loadCount: loadCount, instantLoadWatts: instantWatts)
    }

    /// One battery update a minute from `start`, each minute with its display load and average
    /// system load. The first reading has no instantaneous load, so only these minutes are samples.
    @discardableResult
    private func feed(_ estimator: inout BatteryRuntimeEstimator, _ minutes: [(load: Double, watts: Double)],
                      onAC: Bool = false) -> Date {
        var date = start, sum = 1_000_000.0, count = 100.0
        estimator.record(snapshot(onAC: onAC, loadSum: sum, loadCount: count), at: date)
        for minute in minutes {
            estimator.noteDisplayLoad(minute.load, at: date)
            date += 60
            // A reading a second, in mW.
            sum += minute.watts * 1000 * 60
            count += 60
            estimator.record(snapshot(onAC: onAC, loadSum: sum, loadCount: count), at: date)
        }
        return date
    }

    private func repeated(_ load: Double, _ watts: Double, _ count: Int) -> [(load: Double, watts: Double)] {
        Array(repeating: (load: load, watts: watts), count: count)
    }

    /// Full SDR light and a quarter of it in turns.
    private func alternating(_ full: Double, _ quarter: Double, lowLoad: Double = 0.25,
                             count: Int = 10) -> [(load: Double, watts: Double)] {
        (0..<count).map { $0.isMultiple(of: 2) ? (load: 1.0, watts: full) : (load: lowLoad, watts: quarter) }
    }

    // MARK: Before the history

    func testOnBatteryTheSystemEstimateComesFirst() {
        var estimator = BatteryRuntimeEstimator()
        let status = estimator.add(snapshot(systemMinutes: 260, instantWatts: 20), displayLoad: 0.5, at: start)
        XCTAssertEqual(status, .remaining(percent: 84, minutes: 260))
    }

    func testTheSystemEstimateFollowsABrightnessChange() {
        var estimator = BatteryRuntimeEstimator()
        let battery = snapshot(systemMinutes: 260, instantWatts: 20)
        _ = estimator.add(battery, displayLoad: 1, at: start)

        estimator.noteDisplayLoad(0.25, at: start + 10)
        // macOS's 260 min of 40 Wh is 9.23 W; the display's prior 5 W per unit of light
        // makes a quarter of the light 9.23 - 3.75 = 5.48 W.
        XCTAssertEqual(estimator.status(for: battery, at: start + 10), .remaining(percent: 84, minutes: 438))
    }

    func testARefreshedSystemEstimateIsNotAdjustedForAnOlderBrightness() {
        // macOS's estimate follows about the last minute of current: once that minute is at a
        // quarter of the light, a refreshed estimate already has it.
        var estimator = BatteryRuntimeEstimator()
        let end = feed(&estimator, [(load: 1, watts: 10), (load: 0.25, watts: 6.25)])
        // 40 Wh at 6.25 W, the load macOS saw at a quarter of the light.
        XCTAssertEqual(estimator.status(for: snapshot(systemMinutes: 384), at: end),
                       .remaining(percent: 84, minutes: 384))
    }

    func testWithoutWattHoursTheSystemEstimateStaysAsIs() {
        var estimator = BatteryRuntimeEstimator()
        let battery = snapshot(systemMinutes: 260, wattHours: nil, instantWatts: 20)
        _ = estimator.add(battery, displayLoad: 1, at: start)
        estimator.noteDisplayLoad(0.25, at: start + 10)
        XCTAssertEqual(estimator.status(for: battery, at: start + 10), .remaining(percent: 84, minutes: 260))
    }

    func testFewSamplesStartFromTheSystemEstimate() {
        var four = BatteryRuntimeEstimator()
        let fourEnd = feed(&four, repeated(1, 20, BatteryRuntimeEstimator.minimumSamples - 1))
        XCTAssertEqual(four.status(for: snapshot(systemMinutes: 260), at: fourEnd),
                       .remaining(percent: 84, minutes: 260))

        var five = BatteryRuntimeEstimator()
        let fiveEnd = feed(&five, repeated(1, 20, BatteryRuntimeEstimator.minimumSamples))
        // 40 Wh at the history's 20 W.
        XCTAssertEqual(five.status(for: snapshot(systemMinutes: 260), at: fiveEnd),
                       .remaining(percent: 84, minutes: 120))
    }

    func testOnBatteryWithoutASystemEstimateTheLoadGivesTheTime() {
        var estimator = BatteryRuntimeEstimator()
        // 40 Wh at 10 W.
        XCTAssertEqual(estimator.add(snapshot(instantWatts: 10), displayLoad: 0.5, at: start),
                       .remaining(percent: 84, minutes: 240))
    }

    func testWithoutALoadItIsEstimating() {
        var estimator = BatteryRuntimeEstimator()
        XCTAssertEqual(estimator.add(snapshot(), displayLoad: 0.5, at: start), .estimating(percent: 84))
        XCTAssertEqual(estimator.add(snapshot(wattHours: nil, instantWatts: 10), displayLoad: 0.5, at: start),
                       .estimating(percent: 84))
    }

    func testOnPowerItShowsTheTimeIfUnplugged() {
        var estimator = BatteryRuntimeEstimator()
        // 40 Wh at 8 W.
        let status = estimator.add(snapshot(percent: 80, onAC: true, charging: true, instantWatts: 8),
                                   displayLoad: 0.5, at: start)
        XCTAssertEqual(status, .unplugged(percent: 80, minutes: 300, isCharging: true))
    }

    func testOnPowerWithoutALoadItShowsThePowerState() {
        var estimator = BatteryRuntimeEstimator()
        XCTAssertEqual(estimator.add(snapshot(percent: 100, onAC: true), displayLoad: nil, at: start),
                       .onPower(percent: 100, isCharging: false))
        XCTAssertEqual(estimator.add(snapshot(percent: 50, onAC: true, charging: true), displayLoad: nil, at: start),
                       .onPower(percent: 50, isCharging: true))
    }

    // MARK: History

    func testAccumulatorsAverageTheLoadBetweenBatteryUpdates() {
        var estimator = BatteryRuntimeEstimator()
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100, instantWatts: 20), displayLoad: 0.5, at: start)
        XCTAssertEqual(estimator.samples.map(\.watts), [20], "The first reading seeds the latest load.")

        // 60 readings averaging 10 000 mW since the previous update.
        let status = estimator.add(snapshot(loadSum: 1_600_000, loadCount: 160, instantWatts: 30),
                                   displayLoad: 0.5, at: start + 60)
        XCTAssertEqual(estimator.samples.map(\.watts), [20, 10])
        // 40 Wh at their 15 W.
        XCTAssertEqual(status, .remaining(percent: 84, minutes: 160))
    }

    func testUnchangedAccumulatorsAddNoSample() {
        var estimator = BatteryRuntimeEstimator()
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100, instantWatts: 20), displayLoad: 0.5, at: start)
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100, instantWatts: 30), displayLoad: 0.5,
                          at: start + 40)
        XCTAssertEqual(estimator.samples.map(\.watts), [20], "A momentary load between battery updates is not an average.")
    }

    func testCloseReadingsWaitForTheNextOne() {
        var estimator = BatteryRuntimeEstimator()
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100), displayLoad: 0.5, at: start)
        // 20 W over 20 s, too short a span for a sample.
        _ = estimator.add(snapshot(loadSum: 1_400_000, loadCount: 120), displayLoad: 0.5, at: start + 20)
        XCTAssertEqual(estimator.samples, [])

        _ = estimator.add(snapshot(loadSum: 1_600_000, loadCount: 160), displayLoad: 0.5, at: start + 60)
        XCTAssertEqual(estimator.samples.map(\.watts), [10], "The sample spans the whole minute.")
    }

    func testCounterResetStartsANewBaseline() {
        var estimator = BatteryRuntimeEstimator()
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100, instantWatts: 20), displayLoad: 0.5, at: start)
        _ = estimator.add(snapshot(loadSum: 5_000, loadCount: 2, instantWatts: 12), displayLoad: 0.5, at: start + 60)
        XCTAssertEqual(estimator.samples.map(\.watts), [20], "A reset spans no known load.")

        _ = estimator.add(snapshot(loadSum: 485_000, loadCount: 62), displayLoad: 0.5, at: start + 120)
        XCTAssertEqual(estimator.samples.map(\.watts), [20, 8])
    }

    func testAGapSuchAsSleepAddsNoSample() {
        var estimator = BatteryRuntimeEstimator()
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100, instantWatts: 20), displayLoad: 0.5, at: start)
        let wake = start + BatteryRuntimeEstimator.maximumSampleInterval + 60
        _ = estimator.add(snapshot(loadSum: 1_600_000, loadCount: 160, instantWatts: 12), displayLoad: 0.5, at: wake)
        XCTAssertEqual(estimator.samples.map(\.watts), [20], "The span includes sleep.")

        _ = estimator.add(snapshot(loadSum: 2_080_000, loadCount: 220), displayLoad: 0.5, at: wake + 60)
        XCTAssertEqual(estimator.samples.map(\.watts), [20, 8])
    }

    func testTheHistoryKeepsHalfAnHour() {
        var estimator = BatteryRuntimeEstimator()
        let end = feed(&estimator, repeated(0.5, 10, 40))
        XCTAssertEqual(estimator.samples.count, 30)
        XCTAssertEqual(estimator.samples.first?.date, end - 29 * 60)
    }

    func testAnEmptyHistoryStartsFromTheLatestLoad() {
        var estimator = BatteryRuntimeEstimator()
        let end = feed(&estimator, repeated(0.5, 10, 5))
        _ = estimator.add(snapshot(loadSum: 9_000_000, loadCount: 9_000, instantWatts: 12), displayLoad: 0.5,
                          at: end + BatteryRuntimeEstimator.window)
        XCTAssertEqual(estimator.samples.map(\.watts), [12])
    }

    func testTinyLoadsAreIgnored() {
        var estimator = BatteryRuntimeEstimator()
        XCTAssertEqual(estimator.add(snapshot(instantWatts: 0.2), displayLoad: 0.5, at: start), .estimating(percent: 84))
        XCTAssertEqual(estimator.samples, [])
    }

    func testEachSampleAveragesTheDisplayLoadOverItsSpan() {
        var estimator = BatteryRuntimeEstimator()
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100), displayLoad: 1, at: start)
        estimator.noteDisplayLoad(0.25, at: start + 45)
        _ = estimator.add(snapshot(loadSum: 1_600_000, loadCount: 160), displayLoad: 0.25, at: start + 60)
        // 45 s of full light and 15 s of a quarter.
        XCTAssertEqual(estimator.samples.first?.displayLoad ?? 0, 0.8125, accuracy: 0.0001)
    }

    func testAnUnknownDisplayLoadKeepsTheLastKnownOne() {
        var estimator = BatteryRuntimeEstimator()
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100), displayLoad: 0.6, at: start)
        _ = estimator.add(snapshot(loadSum: 1_600_000, loadCount: 160), displayLoad: nil, at: start + 60)
        _ = estimator.add(snapshot(loadSum: 2_200_000, loadCount: 220), displayLoad: nil, at: start + 120)
        XCTAssertEqual(estimator.samples.map(\.displayLoad), [0.6, 0.6])
    }

    // MARK: The display's share

    func testTheDisplayShareLearnsFromBrightnessChanges() {
        // 12 W at full SDR light and 6 W at a quarter: 8 W per unit of light.
        var ten = BatteryRuntimeEstimator()
        let tenEnd = feed(&ten, alternating(12, 6))
        // The 5 W prior counts as one sample a whole unit of light away: (11.25 + 5) / (1.41 + 1).
        XCTAssertEqual(ten.displayWatts(at: tenEnd), 6.7532, accuracy: 0.001)

        var thirty = BatteryRuntimeEstimator()
        let thirtyEnd = feed(&thirty, alternating(12, 6, count: 30))
        XCTAssertEqual(thirty.displayWatts(at: thirtyEnd), 7.4251, accuracy: 0.001, "More evidence, closer to 8 W.")
    }

    func testTheDisplayShareStaysPlausible() {
        var steep = BatteryRuntimeEstimator()
        let steepEnd = feed(&steep, alternating(30, 2, lowLoad: 0))
        XCTAssertEqual(steep.displayWatts(at: steepEnd), BatteryRuntimeEstimator.displayWattsRange.upperBound)

        var inverse = BatteryRuntimeEstimator()
        let inverseEnd = feed(&inverse, alternating(6, 12))
        XCTAssertEqual(inverse.displayWatts(at: inverseEnd), BatteryRuntimeEstimator.displayWattsRange.lowerBound)

        // The display never takes more than 80% of the average load.
        var light = BatteryRuntimeEstimator()
        let lightEnd = feed(&light, repeated(1, 4, 10))
        XCTAssertEqual(light.displayWatts(at: lightEnd), 3.2, accuracy: 0.0001)
    }

    func testLowerBrightnessGivesMoreTime() {
        var estimator = BatteryRuntimeEstimator()
        let end = feed(&estimator, repeated(1, 10, 10))
        let battery = snapshot(systemMinutes: 250)
        // 40 Wh at the history's 10 W.
        XCTAssertEqual(estimator.status(for: battery, at: end), .remaining(percent: 84, minutes: 240))

        estimator.noteDisplayLoad(0.25, at: end + 5)
        // 10 W - 5 W × 0.75 = 6.25 W.
        XCTAssertEqual(estimator.status(for: battery, at: end + 5), .remaining(percent: 84, minutes: 384))
    }

    func testExtraTakesTime() {
        var estimator = BatteryRuntimeEstimator()
        let end = feed(&estimator, repeated(1, 10, 10))
        estimator.noteDisplayLoad(ScreenBrightnessScale.displayLoad(level: 1, gammaFactor: ScreenBrightnessScale.maximumExtraGamma), at: end + 5)
        // 10 W + 5 W × 1.35 = 16.7 W.
        XCTAssertEqual(estimator.status(for: snapshot(), at: end + 5), .remaining(percent: 84, minutes: 143))
    }

    func testOnPowerTheHistoryGivesTheTimeIfUnplugged() {
        var estimator = BatteryRuntimeEstimator()
        let end = feed(&estimator, repeated(1, 8, 6), onAC: true)
        estimator.noteDisplayLoad(0.25, at: end)
        // 8 W - 5 W × 0.75 = 4.25 W.
        XCTAssertEqual(estimator.status(for: snapshot(percent: 90, onAC: true, charging: true), at: end),
                       .unplugged(percent: 90, minutes: 565, isCharging: true))
    }

    func testMinutesAndPercentAreClamped() {
        XCTAssertEqual(BatteryRuntimeEstimator.minutes(wattHours: 100, watts: 0.5), BatteryRuntimeEstimator.maximumMinutes)
        XCTAssertEqual(BatteryRuntimeEstimator.minutes(wattHours: 0.001, watts: 50), 1)
        XCTAssertNil(BatteryRuntimeEstimator.minutes(wattHours: nil, watts: 10))
        XCTAssertNil(BatteryRuntimeEstimator.minutes(wattHours: 0, watts: 10))
        XCTAssertNil(BatteryRuntimeEstimator.minutes(wattHours: 40, watts: .nan))

        var estimator = BatteryRuntimeEstimator()
        XCTAssertEqual(estimator.add(snapshot(percent: 105, onAC: true), displayLoad: nil, at: start),
                       .onPower(percent: 100, isCharging: false))
        XCTAssertEqual(estimator.add(snapshot(systemMinutes: 5_000), displayLoad: nil, at: start),
                       .remaining(percent: 84, minutes: BatteryRuntimeEstimator.maximumMinutes))
    }

    // MARK: Formatting

    func testDurationRoundsToFiveThenTenMinutes() {
        let cases: [(Int, String)] = [
            (3, "< 5 min"), (5, "5 min"), (23, "25 min"), (57, "55 min"), (58, "1 h"),
            (65, "1 h 10 min"), (123, "2 h"), (260, "4 h 20 min"), (1_440, "24 h"),
        ]
        for (minutes, text) in cases {
            XCTAssertEqual(BatteryRuntimeFormatter.duration(minutes: minutes), text, "\(minutes) min")
        }
    }

    func testStatusTexts() {
        XCTAssertEqual(BatteryRuntimeFormatter.text(for: .remaining(percent: 84, minutes: 260)),
                       "84% · 4 h 20 min left")
        XCTAssertEqual(BatteryRuntimeFormatter.text(for: .estimating(percent: 84)), "84% · Estimating time left…")
        XCTAssertEqual(BatteryRuntimeFormatter.text(for: .unplugged(percent: 84, minutes: 300, isCharging: true)),
                       "84% · 5 h if unplugged")
        XCTAssertEqual(BatteryRuntimeFormatter.text(for: .onPower(percent: 100, isCharging: false)), "100% · On power")
        XCTAssertEqual(BatteryRuntimeFormatter.text(for: .onPower(percent: 50, isCharging: true)), "50% · Charging")
        XCTAssertNil(BatteryRuntimeFormatter.text(for: .hidden))
    }

    func testStatusSymbolsExistOnTheOldestSupportedMacOS() {
        let cases: [(BatteryRuntimeStatus, String?)] = [
            (.remaining(percent: 5, minutes: 20), "battery.0percent"),
            (.remaining(percent: 30, minutes: 60), "battery.25percent"),
            (.estimating(percent: 50), "battery.50percent"),
            (.remaining(percent: 80, minutes: 200), "battery.75percent"),
            (.remaining(percent: 95, minutes: 300), "battery.100percent"),
            (.unplugged(percent: 60, minutes: 300, isCharging: true), "battery.100percent.bolt"),
            (.onPower(percent: 100, isCharging: false), "powerplug.fill"),
            (.hidden, nil),
        ]
        for (status, symbol) in cases {
            XCTAssertEqual(BatteryRuntimeFormatter.systemImage(for: status), symbol, "\(status)")
        }
    }
}

@MainActor
final class BatteryRuntimeMonitorTests: XCTestCase {
    func testMonitorPublishesTheStatusAndHidesWithoutABattery() {
        var reading: BatterySnapshot? = BatterySnapshot(percent: 84, isOnAC: false, isCharging: false,
                                                        systemMinutesToEmpty: 260)
        let monitor = BatteryRuntimeMonitor(read: { reading }, now: { Date(timeIntervalSince1970: 10_000) })
        XCTAssertEqual(monitor.status, .hidden)

        monitor.start()
        XCTAssertEqual(monitor.status, .remaining(percent: 84, minutes: 260))

        reading = nil
        monitor.sample()
        XCTAssertEqual(monitor.status, .hidden)
        monitor.stop()
    }

    func testUnchangedSamplesPublishNothing() {
        let monitor = BatteryRuntimeMonitor(read: {
            BatterySnapshot(percent: 84, isOnAC: false, isCharging: false, systemMinutesToEmpty: 260)
        }, now: { Date(timeIntervalSince1970: 10_000) })
        monitor.sample()
        var announcements = 0
        let subscription = monitor.objectWillChange.sink { announcements += 1 }
        defer { subscription.cancel() }

        monitor.sample()
        monitor.sample()
        XCTAssertEqual(announcements, 0)
    }

    func testADisplayChangeRecomputesWithoutReadingTheBattery() {
        var reads = 0
        var load: Double? = 1
        let monitor = BatteryRuntimeMonitor(read: {
            reads += 1
            return BatterySnapshot(percent: 84, isOnAC: false, isCharging: false, systemMinutesToEmpty: 260,
                                   remainingWattHours: 40, instantLoadWatts: 20)
        }, displayLoad: { load }, now: { Date(timeIntervalSince1970: 10_000) })
        monitor.sample()
        XCTAssertEqual(monitor.status, .remaining(percent: 84, minutes: 260))

        load = 0.25
        monitor.displayDidChange()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(monitor.status, .remaining(percent: 84, minutes: 438))
    }

    func testHistoryRecordsFromLaunchWithoutAStrip() {
        let monitor = BatteryRuntimeMonitor(read: {
            BatterySnapshot(percent: 84, isOnAC: false, isCharging: false, systemMinutesToEmpty: 260)
        }, now: { Date(timeIntervalSince1970: 10_000) })
        monitor.startHistory()
        defer { monitor.stopHistory() }
        XCTAssertTrue(monitor.isRecordingHistory)
        XCTAssertFalse(monitor.isSampling, "The history is not a visible strip's polling.")
        XCTAssertEqual(monitor.status, .remaining(percent: 84, minutes: 260), "It reads at once.")

        monitor.start()
        monitor.stop()
        XCTAssertTrue(monitor.isRecordingHistory, "Closing the strip keeps the history.")
    }

    func testWithoutABatteryThereIsNoHistory() {
        let monitor = BatteryRuntimeMonitor(read: { nil })
        monitor.startHistory()
        XCTAssertFalse(monitor.isRecordingHistory)
        XCTAssertEqual(monitor.status, .hidden)
    }
}
