import Foundation
import IOKit
import IOKit.ps

/// One reading of the internal battery. Power values come from AppleSmartBattery,
/// which refreshes its telemetry about once a minute.
struct BatterySnapshot: Equatable {
    var percent: Int
    var isOnAC: Bool
    var isCharging: Bool
    /// macOS's own estimate; nil while it is calculating and on power.
    var systemMinutesToEmpty: Int?
    var remainingWattHours: Double?
    /// Running sum of system load samples (mW) and their count since boot.
    var loadSum: Double?
    var loadCount: Double?
    /// The system load at the battery's latest update.
    var instantLoadWatts: Double?
}

enum BatteryRuntimeStatus: Equatable {
    /// No internal battery: the strip shows no battery line.
    case hidden
    case remaining(percent: Int, minutes: Int)
    case estimating(percent: Int)
    /// On power: how long the current load would last without charging.
    case unplugged(percent: Int, minutes: Int, isCharging: Bool)
    case onPower(percent: Int, isCharging: Bool)
}

/// Turns battery snapshots into a runtime at the current load. The average load
/// comes from AppleSmartBattery's accumulators, so momentary spikes do not swing it.
struct BatteryRuntimeEstimator {
    static let maximumMinutes = 24 * 60
    static let minimumLoadWatts = 0.5
    /// A baseline or average older than this no longer describes the current load.
    static let staleInterval: TimeInterval = 5 * 60
    /// Weight of each new per-minute average.
    static let smoothing = 0.5

    private(set) var averageWatts: Double?
    private var baseline: (sum: Double, count: Double, date: Date)?
    private var lastSample: Date?

    mutating func add(_ snapshot: BatterySnapshot, at date: Date) -> BatteryRuntimeStatus {
        recordLoad(snapshot, at: date)
        return status(for: snapshot)
    }

    func status(for snapshot: BatterySnapshot) -> BatteryRuntimeStatus {
        let percent = min(max(0, snapshot.percent), 100)
        let computed = Self.minutes(wattHours: snapshot.remainingWattHours, watts: averageWatts)
        if snapshot.isOnAC {
            guard let computed else { return .onPower(percent: percent, isCharging: snapshot.isCharging) }
            return .unplugged(percent: percent, minutes: computed, isCharging: snapshot.isCharging)
        }
        if let system = snapshot.systemMinutesToEmpty, system > 0 {
            return .remaining(percent: percent, minutes: min(system, Self.maximumMinutes))
        }
        guard let computed else { return .estimating(percent: percent) }
        return .remaining(percent: percent, minutes: computed)
    }

    static func minutes(wattHours: Double?, watts: Double?) -> Int? {
        guard let wattHours, let watts, wattHours.isFinite, watts.isFinite,
              wattHours > 0, watts >= minimumLoadWatts else { return nil }
        return min(max(1, Int((wattHours / watts * 60).rounded())), maximumMinutes)
    }

    private mutating func recordLoad(_ snapshot: BatterySnapshot, at date: Date) {
        if let lastSample, date.timeIntervalSince(lastSample) > Self.staleInterval { averageWatts = nil }
        guard let sum = snapshot.loadSum, let count = snapshot.loadCount else {
            if let instant = snapshot.instantLoadWatts { feed(instant, at: date) }
            return
        }
        if let baseline, date.timeIntervalSince(baseline.date) <= Self.staleInterval,
           count >= baseline.count, sum >= baseline.sum {
            guard count > baseline.count else { return }
            self.baseline = (sum, count, date)
            feed((sum - baseline.sum) / (count - baseline.count) / 1000, at: date)
            return
        }
        // First reading, a long pause or a counter reset: start a new baseline and
        // use the latest instantaneous load until the next battery update.
        baseline = (sum, count, date)
        averageWatts = nil
        if let instant = snapshot.instantLoadWatts { feed(instant, at: date) }
    }

    private mutating func feed(_ watts: Double, at date: Date) {
        guard watts.isFinite, watts >= Self.minimumLoadWatts else { return }
        averageWatts = averageWatts.map { $0 + Self.smoothing * (watts - $0) } ?? watts
        lastSample = date
    }
}

enum BatteryRuntimeFormatter {
    static func text(for status: BatteryRuntimeStatus) -> String? {
        switch status {
        case .hidden: return nil
        case let .remaining(percent, minutes): return "\(percent)% · \(duration(minutes: minutes)) left"
        case let .estimating(percent): return "\(percent)% · Estimating time left…"
        case let .unplugged(percent, minutes, _): return "\(percent)% · \(duration(minutes: minutes)) if unplugged"
        case let .onPower(percent, isCharging): return "\(percent)% · \(isCharging ? "Charging" : "On power")"
        }
    }

    /// Under an hour in five-minute steps, then ten-minute steps: "25 min", "4 h 20 min".
    static func duration(minutes: Int) -> String {
        guard minutes >= 5 else { return "< 5 min" }
        let step = minutes < 60 ? 5 : 10
        let rounded = Int((Double(minutes) / Double(step)).rounded()) * step
        guard rounded >= 60 else { return "\(rounded) min" }
        let hours = rounded / 60, rest = rounded % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    static func systemImage(for status: BatteryRuntimeStatus) -> String? {
        switch status {
        case .hidden: return nil
        case let .remaining(percent, _), let .estimating(percent): return levelImage(percent: percent)
        case let .unplugged(_, _, isCharging), let .onPower(_, isCharging):
            // powerplug.portrait.fill needs macOS 15; the app supports macOS 14.
            return isCharging ? "battery.100percent.bolt" : "powerplug.fill"
        }
    }

    private static func levelImage(percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Public power-source keys plus AppleSmartBattery registry properties. Reads only.
final class IOKitBatteryReader {
    private var service: io_service_t = IO_OBJECT_NULL

    deinit { if service != IO_OBJECT_NULL { IOObjectRelease(service) } }

    func read() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool != false,
                  let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                  let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
                  maximum > 0 else { continue }
            let isOnAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let timeToEmpty = (description[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue
            var snapshot = BatterySnapshot(
                percent: Int((current / maximum * 100).rounded()),
                isOnAC: isOnAC,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                systemMinutesToEmpty: isOnAC ? nil : timeToEmpty.flatMap { $0 > 0 ? $0 : nil })
            readRegistry(into: &snapshot)
            return snapshot
        }
        return nil
    }

    private func readRegistry(into snapshot: inout BatterySnapshot) {
        if service == IO_OBJECT_NULL {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        guard service != IO_OBJECT_NULL else { return }
        let batteryData = property("BatteryData") as? [String: Any]
        let telemetry = property("PowerTelemetryData") as? [String: Any]
        let milliampHours = Self.number(batteryData?["AppleRawCurrentCapacity"])
            ?? Self.number(property("AppleRawCurrentCapacity"))
        if let milliampHours, let millivolts = Self.number(property("Voltage")) {
            snapshot.remainingWattHours = milliampHours * millivolts / 1_000_000
        }
        snapshot.loadSum = Self.number(telemetry?["AccumulatedSystemLoad"])
        snapshot.loadCount = Self.number(telemetry?["SystemLoadAccumulatorCount"])
        snapshot.instantLoadWatts = Self.number(telemetry?["SystemLoad"]).map { $0 / 1000 }
    }

    private func property(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = (value as? NSNumber)?.doubleValue, value.isFinite else { return nil }
        return value
    }
}

/// Shared by every visible Brightness strip; samples only while one is shown.
@MainActor
final class BatteryRuntimeMonitor: ObservableObject {
    static let shared = BatteryRuntimeMonitor()
    static let pollInterval: TimeInterval = 5

    @Published private(set) var status: BatteryRuntimeStatus = .hidden

    private let read: () -> BatterySnapshot?
    private let now: () -> Date
    private var estimator = BatteryRuntimeEstimator()
    private var timer: Timer?
    private var viewers = 0
    /// True while a visible strip samples the battery.
    var isSampling: Bool { timer != nil }

    init(read: (() -> BatterySnapshot?)? = nil, now: @escaping () -> Date = Date.init) {
        if let read {
            self.read = read
        } else {
            let reader = IOKitBatteryReader()
            self.read = { reader.read() }
        }
        self.now = now
    }

    func start() {
        viewers += 1
        sample()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func sample() {
        let next = read().map { estimator.add($0, at: now()) } ?? .hidden
        if status != next { status = next }
    }
}
