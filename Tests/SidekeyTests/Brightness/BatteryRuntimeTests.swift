import Combine
import XCTest
@testable import Sidekey

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

    // MARK: Estimates

    func testOnBatteryTheSystemEstimateComesFirst() {
        var estimator = BatteryRuntimeEstimator()
        let status = estimator.add(snapshot(systemMinutes: 260, instantWatts: 20), at: start)
        XCTAssertEqual(status, .remaining(percent: 84, minutes: 260))
    }

    func testOnBatteryWithoutASystemEstimateTheLoadGivesTheTime() {
        var estimator = BatteryRuntimeEstimator()
        // 40 Wh at 10 W.
        let status = estimator.add(snapshot(instantWatts: 10), at: start)
        XCTAssertEqual(status, .remaining(percent: 84, minutes: 240))
    }

    func testWithoutALoadItIsEstimating() {
        var estimator = BatteryRuntimeEstimator()
        XCTAssertEqual(estimator.add(snapshot(), at: start), .estimating(percent: 84))
        XCTAssertEqual(estimator.add(snapshot(wattHours: nil, instantWatts: 10), at: start),
                       .estimating(percent: 84))
    }

    func testOnPowerItShowsTheTimeIfUnplugged() {
        var estimator = BatteryRuntimeEstimator()
        // 40 Wh at 8 W.
        let status = estimator.add(snapshot(percent: 80, onAC: true, charging: true, instantWatts: 8), at: start)
        XCTAssertEqual(status, .unplugged(percent: 80, minutes: 300, isCharging: true))
    }

    func testOnPowerWithoutALoadItShowsThePowerState() {
        var estimator = BatteryRuntimeEstimator()
        XCTAssertEqual(estimator.add(snapshot(percent: 100, onAC: true), at: start),
                       .onPower(percent: 100, isCharging: false))
        XCTAssertEqual(estimator.add(snapshot(percent: 50, onAC: true, charging: true), at: start),
                       .onPower(percent: 50, isCharging: true))
    }

    func testAccumulatorsAverageTheLoadBetweenBatteryUpdates() {
        var estimator = BatteryRuntimeEstimator()
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100, instantWatts: 20), at: start)
        XCTAssertEqual(estimator.averageWatts, 20, "The first reading seeds the latest load.")

        // 60 samples averaging 10 000 mW since the previous update.
        let status = estimator.add(snapshot(loadSum: 1_600_000, loadCount: 160, instantWatts: 30),
                                   at: start + 60)
        XCTAssertEqual(estimator.averageWatts ?? 0, 15, accuracy: 0.0001)
        XCTAssertEqual(status, .remaining(percent: 84, minutes: 160))
    }

    func testUnchangedAccumulatorsKeepTheAverage() {
        var estimator = BatteryRuntimeEstimator()
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100, instantWatts: 20), at: start)
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100, instantWatts: 30), at: start + 5)
        XCTAssertEqual(estimator.averageWatts, 20, "A momentary load between battery updates is not an average.")
    }

    func testCounterResetStartsANewBaseline() {
        var estimator = BatteryRuntimeEstimator()
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100, instantWatts: 20), at: start)
        _ = estimator.add(snapshot(loadSum: 5_000, loadCount: 2, instantWatts: 12), at: start + 60)
        XCTAssertEqual(estimator.averageWatts, 12)
    }

    func testALongPauseDropsTheOldAverage() {
        var estimator = BatteryRuntimeEstimator()
        _ = estimator.add(snapshot(loadSum: 1_000_000, loadCount: 100, instantWatts: 20), at: start)
        _ = estimator.add(snapshot(loadSum: 1_600_000, loadCount: 160, instantWatts: 12),
                          at: start + BatteryRuntimeEstimator.staleInterval + 100)
        XCTAssertEqual(estimator.averageWatts, 12, "A stale average no longer describes the current load.")
    }

    func testTinyLoadsAreIgnored() {
        var estimator = BatteryRuntimeEstimator()
        XCTAssertEqual(estimator.add(snapshot(instantWatts: 0.2), at: start), .estimating(percent: 84))
        XCTAssertNil(estimator.averageWatts)
    }

    func testMinutesAndPercentAreClamped() {
        XCTAssertEqual(BatteryRuntimeEstimator.minutes(wattHours: 100, watts: 0.5), BatteryRuntimeEstimator.maximumMinutes)
        XCTAssertEqual(BatteryRuntimeEstimator.minutes(wattHours: 0.001, watts: 50), 1)
        XCTAssertNil(BatteryRuntimeEstimator.minutes(wattHours: nil, watts: 10))
        XCTAssertNil(BatteryRuntimeEstimator.minutes(wattHours: 0, watts: 10))
        XCTAssertNil(BatteryRuntimeEstimator.minutes(wattHours: 40, watts: .nan))

        var estimator = BatteryRuntimeEstimator()
        XCTAssertEqual(estimator.add(snapshot(percent: 105, onAC: true), at: start),
                       .onPower(percent: 100, isCharging: false))
        XCTAssertEqual(estimator.add(snapshot(systemMinutes: 5_000), at: start),
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
}
