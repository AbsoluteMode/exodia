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

/// Turns battery readings into a runtime at the current load. The last half hour of system load,
/// averaged between readings by AppleSmartBattery's accumulators, gives the load; the built-in
/// display's share of it follows the current brightness and Extra, so the time left changes with
/// them. Kept in memory only.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
struct BatteryRuntimeEstimator {
    static let maximumMinutes = 24 * 60
    static let minimumLoadWatts = 0.5
    /// The load history the estimate averages.
    static let window: TimeInterval = 30 * 60
    /// The telemetry refreshes about once a minute; a shorter span waits for the next reading.
    static let minimumSampleInterval: TimeInterval = 30
    /// A longer span includes sleep or a pause, whose load is unknown.
    static let maximumSampleInterval: TimeInterval = 180
    /// Until the history has this many samples, macOS's own estimate comes first.
    static let minimumSamples = 5
    /// The built-in display's watts per unit of light (its full SDR white) until the history
    /// shows its own: an assumption for a 14-16" XDR panel.
    static let priorDisplayWatts = 5.0
    /// The prior counts as one sample a whole unit of light from the history's mean.
    static let priorWeight = 1.0
    static let displayWattsRange = 1.0...15.0
    /// The display never takes more of the average load than this.
    static let maximumDisplayShare = 0.8
    /// macOS's estimate follows the battery's average current, about the last minute: the light
    /// over that minute is the one it was made at (an assumption).
    static let systemEstimateSpan: TimeInterval = 60

    struct Sample: Equatable {
        var date: Date
        /// The system load averaged over the sample's span.
        var watts: Double
        /// The built-in display's light averaged over the same span (`ScreenBrightnessScale.displayLoad`).
        var displayLoad: Double
    }

    private struct Counters {
        var sum: Double
        var count: Double
    }

    /// The last half hour, oldest first.
    private(set) var samples: [Sample] = []
    /// The reading the next sample spans from.
    private var baseline: (counters: Counters?, date: Date)?
    /// The built-in display's latest known light and since when.
    private var load: (value: Double, since: Date)?
    /// The light's changes over the last `systemEstimateSpan`, oldest first.
    private var recentLoads: [(value: Double, since: Date)] = []
    /// The light the latest reading's macOS estimate was made at.
    private var systemEstimateLoad: Double?
    /// The light integrated over the known time since the baseline.
    private var loadArea = 0.0
    private var loadDuration: TimeInterval = 0

    /// The built-in display's light from `date` on. An unknown light keeps the last known one.
    mutating func noteDisplayLoad(_ value: Double?, at date: Date) {
        guard let value, value.isFinite else { return }
        let integrated = integratedLoad(until: date)
        loadArea = integrated.area
        loadDuration = integrated.duration
        load = (max(0, value), date)
        recentLoads.append((max(0, value), date))
        // Changes before the span matter only through the last one, which lasted into it.
        while recentLoads.count > 1, recentLoads[1].since <= date - Self.systemEstimateSpan {
            recentLoads.removeFirst()
        }
    }

    /// A battery reading. Once the accumulators move on, their average since the baseline
    /// becomes a sample with the display's average light over the same span.
    mutating func record(_ snapshot: BatterySnapshot, at date: Date) {
        systemEstimateLoad = recentMeanLoad(until: date)
        samples.removeAll { date.timeIntervalSince($0.date) >= Self.window }
        let counters = snapshot.loadSum.flatMap { sum in snapshot.loadCount.map { Counters(sum: sum, count: $0) } }
        // Without telemetry there is no load to learn from.
        guard counters != nil || snapshot.instantLoadWatts != nil else { return }
        guard let baseline, continuesBaseline(with: counters, at: date) else {
            // The first reading, a gap such as sleep, a counter reset or a clock change. An empty
            // history starts from the latest load until the next reading.
            restart(at: date, counters: counters)
            if samples.isEmpty, let instant = snapshot.instantLoadWatts, instant.isFinite,
               instant >= Self.minimumLoadWatts {
                samples.append(Sample(date: date, watts: instant, displayLoad: load?.value ?? 0))
            }
            return
        }
        guard date.timeIntervalSince(baseline.date) >= Self.minimumSampleInterval else { return }
        let watts: Double
        if let base = baseline.counters, let counters {
            // Unchanged accumulators: the battery has not updated since the baseline.
            guard counters.count > base.count else { return }
            watts = (counters.sum - base.sum) / (counters.count - base.count) / 1000
        } else {
            watts = snapshot.instantLoadWatts ?? 0
        }
        let light = meanDisplayLoad(until: date)
        restart(at: date, counters: counters)
        guard watts.isFinite, watts >= Self.minimumLoadWatts else { return }
        samples.append(Sample(date: date, watts: watts, displayLoad: light))
    }

    func status(for snapshot: BatterySnapshot, at date: Date) -> BatteryRuntimeStatus {
        let percent = min(max(0, snapshot.percent), 100)
        let history = history(at: date)
        let light = load?.value ?? 0
        let fromHistory = Self.minutes(wattHours: snapshot.remainingWattHours,
                                       watts: Self.predictedWatts(history, light: light))
        if snapshot.isOnAC {
            guard let fromHistory else { return .onPower(percent: percent, isCharging: snapshot.isCharging) }
            return .unplugged(percent: percent, minutes: fromHistory, isCharging: snapshot.isCharging)
        }
        if let system = snapshot.systemMinutesToEmpty, system > 0,
           history.count < Self.minimumSamples || fromHistory == nil {
            let minutes = systemMinutes(system, wattHours: snapshot.remainingWattHours, history: history,
                                        light: light)
            return .remaining(percent: percent, minutes: minutes)
        }
        guard let fromHistory else { return .estimating(percent: percent) }
        return .remaining(percent: percent, minutes: fromHistory)
    }

    /// The built-in display's watts per unit of light that the history at `date` shows.
    func displayWatts(at date: Date) -> Double {
        let history = history(at: date)
        return Self.displayWatts(history, meanWatts: Self.mean(history.map(\.watts)),
                                 meanLoad: Self.mean(history.map(\.displayLoad)))
    }

    static func minutes(wattHours: Double?, watts: Double?) -> Int? {
        guard let wattHours, let watts, wattHours.isFinite, watts.isFinite,
              wattHours > 0, watts >= minimumLoadWatts else { return nil }
        return min(max(1, Int((wattHours / watts * 60).rounded())), maximumMinutes)
    }

    private func history(at date: Date) -> [Sample] {
        samples.filter { date.timeIntervalSince($0.date) < Self.window }
    }

    /// Soon enough after the baseline, with the same kind of telemetry and accumulators that only grew.
    private func continuesBaseline(with counters: Counters?, at date: Date) -> Bool {
        guard let baseline else { return false }
        let span = date.timeIntervalSince(baseline.date)
        guard span > 0, span <= Self.maximumSampleInterval else { return false }
        switch (baseline.counters, counters) {
        case (nil, nil): return true
        case let (base?, current?): return current.sum >= base.sum && current.count >= base.count
        default: return false
        }
    }

    private mutating func restart(at date: Date, counters: Counters?) {
        baseline = (counters, date)
        loadArea = 0
        loadDuration = 0
    }

    /// The light integrated from the baseline until `date`, the current light's span included.
    private func integratedLoad(until date: Date) -> (area: Double, duration: TimeInterval) {
        guard let load, let baseline else { return (loadArea, loadDuration) }
        let from = max(load.since, baseline.date)
        guard date > from else { return (loadArea, loadDuration) }
        let span = date.timeIntervalSince(from)
        return (loadArea + load.value * span, loadDuration + span)
    }

    private func meanDisplayLoad(until date: Date) -> Double {
        let integrated = integratedLoad(until: date)
        return integrated.duration > 0 ? integrated.area / integrated.duration : load?.value ?? 0
    }

    /// The light over the last `systemEstimateSpan` before `date`; without a span known, the light then.
    private func recentMeanLoad(until date: Date) -> Double? {
        let from = date - Self.systemEstimateSpan
        var area = 0.0, duration: TimeInterval = 0
        for (index, entry) in recentLoads.enumerated() {
            let end = index + 1 < recentLoads.count ? min(recentLoads[index + 1].since, date) : date
            let start = max(entry.since, from)
            guard end > start else { continue }
            area += entry.value * end.timeIntervalSince(start)
            duration += end.timeIntervalSince(start)
        }
        return duration > 0 ? area / duration : load?.value
    }

    /// macOS's estimate with the display's share moved from the light it was made at (the last
    /// minute's before the reading) to the current light.
    private func systemMinutes(_ system: Int, wattHours: Double?, history: [Sample], light: Double) -> Int {
        let fallback = min(system, Self.maximumMinutes)
        guard let wattHours, wattHours.isFinite, wattHours > 0 else { return fallback }
        let watts = wattHours * 60 / Double(system)
        let madeAt = systemEstimateLoad ?? light
        let adjusted = watts + Self.displayWatts(history, meanWatts: watts, meanLoad: madeAt) * (light - madeAt)
        return Self.minutes(wattHours: wattHours, watts: max(adjusted, Self.minimumLoadWatts)) ?? fallback
    }

    /// The history's average load with the display's share at the current light.
    private static func predictedWatts(_ history: [Sample], light: Double) -> Double? {
        guard !history.isEmpty else { return nil }
        let watts = mean(history.map(\.watts)), madeAt = mean(history.map(\.displayLoad))
        return max(watts + displayWatts(history, meanWatts: watts, meanLoad: madeAt) * (light - madeAt),
                   minimumLoadWatts)
    }

    /// The load's least-squares slope over the display's light, drawn toward the prior while the
    /// brightness has barely changed and bounded to a plausible panel. The display's share of
    /// `meanWatts` at `meanLoad` stays within `maximumDisplayShare`.
    private static func displayWatts(_ history: [Sample], meanWatts: Double, meanLoad: Double) -> Double {
        let watts = mean(history.map(\.watts)), light = mean(history.map(\.displayLoad))
        var spread = 0.0, covariance = 0.0
        for sample in history {
            spread += (sample.displayLoad - light) * (sample.displayLoad - light)
            covariance += (sample.displayLoad - light) * (sample.watts - watts)
        }
        let fitted = (covariance + priorWeight * priorDisplayWatts) / (spread + priorWeight)
        let bounded = min(max(fitted, displayWattsRange.lowerBound), displayWattsRange.upperBound)
        guard meanLoad > 0 else { return bounded }
        return min(bounded, maximumDisplayShare * meanWatts / meanLoad)
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
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

/// Records the battery history from launch, a reading a minute, and samples every 5 s while a
/// Display strip is shown. A brightness or Extra change recomputes the time left at once.
/// Readings stay in memory: never persisted, logged or sent.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
final class BatteryRuntimeMonitor: ObservableObject {
    static let shared = BatteryRuntimeMonitor(displayLoad: { ScreenBrightnessController.shared.builtInDisplayLoad() })
    static let pollInterval: TimeInterval = 5
    /// AppleSmartBattery refreshes its telemetry about once a minute.
    static let historyInterval: TimeInterval = 60

    @Published private(set) var status: BatteryRuntimeStatus = .hidden

    private let read: () -> BatterySnapshot?
    private let displayLoad: @MainActor () -> Double?
    private let now: () -> Date
    private var estimator = BatteryRuntimeEstimator()
    /// The latest reading, for recomputing between readings.
    private var snapshot: BatterySnapshot?
    private var timer: Timer?
    private var historyTimer: Timer?
    private var viewers = 0
    /// True while a visible strip samples the battery.
    var isSampling: Bool { timer != nil }
    var isRecordingHistory: Bool { historyTimer != nil }

    /// Without `displayLoad` the estimate sees no display, so tests never read a real one.
    init(read: (() -> BatterySnapshot?)? = nil, displayLoad: @escaping @MainActor () -> Double? = { nil },
         now: @escaping () -> Date = Date.init) {
        if let read {
            self.read = read
        } else {
            let reader = IOKitBatteryReader()
            self.read = { reader.read() }
        }
        self.displayLoad = displayLoad
        self.now = now
    }

    /// A Mac without a battery records nothing.
    func startHistory() {
        guard historyTimer == nil else { return }
        sample()
        guard snapshot != nil else { return }
        let timer = Timer(timeInterval: Self.historyInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 10
        historyTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopHistory() {
        historyTimer?.invalidate()
        historyTimer = nil
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
        let date = now()
        guard let next = read() else {
            snapshot = nil
            publish(.hidden)
            return
        }
        estimator.noteDisplayLoad(displayLoad(), at: date)
        estimator.record(next, at: date)
        snapshot = next
        publish(estimator.status(for: next, at: date))
    }

    /// The display's brightness or Extra changed: recompute without reading the battery.
    func displayDidChange() {
        let date = now()
        estimator.noteDisplayLoad(displayLoad(), at: date)
        guard let snapshot else { return }
        publish(estimator.status(for: snapshot, at: date))
    }

    /// Assigns only a changed status: `@Published` announces every assignment.
    private func publish(_ next: BatteryRuntimeStatus) {
        if status != next { status = next }
    }
}
