import CoreGraphics
import Foundation

/// One display's transfer table: the output Quartz gives each encoded channel value.
struct DisplayGammaTable: Equatable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]

    /// The brightest output of any channel; a display's own table ends at SDR white.
    var peak: Float { max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0) }

    func scaled(by factor: Double) -> DisplayGammaTable {
        let factor = Float(factor)
        return DisplayGammaTable(red: red.map { $0 * factor }, green: green.map { $0 * factor },
                                 blue: blue.map { $0 * factor })
    }

    /// Quartz may resample a written table, so only each channel's white is compared.
    func matches(_ other: DisplayGammaTable) -> Bool {
        [(red.last, other.red.last), (green.last, other.green.last), (blue.last, other.blue.last)]
            .allSatisfy { mine, theirs in
                guard let mine, let theirs else { return false }
                return abs(mine - theirs) <= 0.003
            }
    }
}

@MainActor
protocol DisplayGammaAccess {
    func read(_ id: CGDirectDisplayID) -> DisplayGammaTable?
    func write(_ table: DisplayGammaTable, to id: CGDirectDisplayID) -> Bool
    /// Gives every display its ColorSync table back.
    func restoreColorSyncSettings()
}

/// Quartz gives every display its own table back when this process exits, crashes included.
@MainActor
struct QuartzDisplayGamma: DisplayGammaAccess {
    static let capacity = 256

    func read(_ id: CGDirectDisplayID) -> DisplayGammaTable? {
        var red = [CGGammaValue](repeating: 0, count: Self.capacity)
        var green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, UInt32(Self.capacity), &red, &green, &blue, &count) == .success,
              count > 0 else { return nil }
        let filled = Int(count)
        return DisplayGammaTable(red: Array(red.prefix(filled)), green: Array(green.prefix(filled)),
                                 blue: Array(blue.prefix(filled)))
    }

    func write(_ table: DisplayGammaTable, to id: CGDirectDisplayID) -> Bool {
        let count = table.red.count
        guard count > 0, table.green.count == count, table.blue.count == count else { return false }
        return CGSetDisplayTransferByTable(id, UInt32(count), table.red, table.green, table.blue) == .success
    }

    func restoreColorSyncSettings() { CGDisplayRestoreColorSyncSettings() }
}

/// Extra, as Vivid does it: the display's own transfer table scaled into the EDR headroom
/// that `BrightnessHeadroomTrigger` keeps engaged. The display applies the table after
/// WindowServer composites the desktop, so recompositing on an app switch cannot dim it.
/// Ends are reported once, synchronously; close reports nothing.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
final class GammaBrightnessBoost {
    /// WindowServer raised the headroom within about 0.7 s of the first EDR frame (2026-10-19).
    nonisolated static let engageTimeout: TimeInterval = 5
    /// A different headroom must hold this long before a boosting table follows it.
    nonisolated static let settleInterval: TimeInterval = 1.5
    /// This many resets of the table within the interval mean another app keeps writing it.
    nonisolated static let resetLimit = (count: 3, interval: 10.0)
    /// Below this the trigger has not engaged EDR yet.
    nonisolated static let engagedHeadroom = 1.05
    /// A table ending above this already boosts the display.
    nonisolated static let neutralPeak: Float = 1.01
    nonisolated static let factorTolerance = 0.005

    private enum Phase {
        /// Nothing is written until the trigger's frames raise the headroom.
        case engaging(since: Date)
        /// The headroom is rising; each step is followed at once.
        case ramping
        case boosting
        /// Another user's session is active and the display has its own table.
        case suspended
        case ended
    }

    private let display: CGDirectDisplayID
    private let gamma: DisplayGammaAccess
    private let headroom: () -> Double
    private let now: () -> Date
    private let onEnd: (BrightnessBoostEnd) -> Void
    private var phase: Phase
    /// The display's own table, given back on close.
    private var base: DisplayGammaTable?
    /// The factor the display currently has over `base`.
    private var factor = 1.0
    /// Since when the headroom has asked for a different factor.
    private var pendingSince: Date?
    private var resets: [Date] = []

    init(display: CGDirectDisplayID, gamma: DisplayGammaAccess, headroom: @escaping () -> Double,
         now: @escaping () -> Date = Date.init, onEnd: @escaping (BrightnessBoostEnd) -> Void) {
        self.display = display
        self.gamma = gamma
        self.headroom = headroom
        self.now = now
        self.onEnd = onEnd
        phase = .engaging(since: now())
    }

    /// After each trigger frame.
    func tick() {
        switch phase {
        case .suspended, .ended: return
        case .engaging(let since): engage(since: since)
        case .ramping, .boosting:
            guard holdTable() else { return }
            follow(ScreenBrightnessScale.extraGammaFactor(currentHeadroom: headroom()))
        }
    }

    /// The table belongs to the display, so another user's session would see the boost.
    func suspend() {
        switch phase {
        case .suspended, .ended: return
        case .engaging: break
        case .ramping, .boosting: giveBack()
        }
        phase = .suspended
    }

    func resume() {
        guard case .suspended = phase else { return }
        phase = .engaging(since: now())
    }

    /// Switching Extra off is not an end to report.
    func close() {
        switch phase {
        case .ended: return
        case .engaging, .suspended: break
        case .ramping, .boosting: giveBack()
        }
        phase = .ended
    }

    private func engage(since: Date) {
        let current = headroom()
        guard current.isFinite, current > Self.engagedHeadroom else {
            if now().timeIntervalSince(since) >= Self.engageTimeout { end(.unavailable) }
            return
        }
        guard let table = gamma.read(display) else { return end(.unavailable) }
        // Vivid's table already ends above SDR white; scaling it again would clip.
        guard table.peak <= Self.neutralPeak else { return end(.otherApp) }
        base = table
        factor = 1
        pendingSince = nil
        resets = []
        guard apply(ScreenBrightnessScale.extraGammaFactor(currentHeadroom: current), over: table) else {
            // Nothing was written, so nothing is given back.
            base = nil
            return end(.unavailable)
        }
        phase = .ramping
    }

    /// False once the boost has ended. A display reconfiguration or a profile change
    /// restores the display's own table, which is then boosted again.
    private func holdTable() -> Bool {
        guard let base else { return false }
        guard let table = gamma.read(display) else {
            giveBack()
            end(.unavailable)
            return false
        }
        if table.matches(base.scaled(by: factor)) { return true }
        guard table.peak <= Self.neutralPeak else {
            // Another booster took the display over; its table stays.
            end(.otherApp)
            return false
        }
        let date = now()
        resets = resets.filter { date.timeIntervalSince($0) < Self.resetLimit.interval } + [date]
        guard resets.count < Self.resetLimit.count else {
            end(.otherApp)
            return false
        }
        self.base = table
        guard apply(factor, over: table) else {
            fail()
            return false
        }
        return true
    }

    private func follow(_ target: Double) {
        let tolerance = Self.factorTolerance
        // Returning headroom rises as it did the first time.
        if case .boosting = phase, factor <= 1 + tolerance, target > factor + tolerance { phase = .ramping }
        if abs(target - factor) <= tolerance {
            pendingSince = nil
            if case .ramping = phase { phase = .boosting }
            return
        }
        if case .ramping = phase, target > factor {
            write(target)
            return
        }
        // Stepping the table down and back up for a brief dip would itself blink. Without
        // headroom the target is the display's own table: the boosted white would clip.
        phase = .boosting
        let date = now()
        let since = pendingSince ?? date
        pendingSince = since
        guard date.timeIntervalSince(since) >= Self.settleInterval else { return }
        write(target)
    }

    private func write(_ next: Double) {
        guard let base, apply(next, over: base) else { return fail() }
        pendingSince = nil
    }

    private func apply(_ next: Double, over table: DisplayGammaTable) -> Bool {
        guard gamma.write(table.scaled(by: next), to: display) else { return false }
        factor = next
        return true
    }

    private func fail() {
        giveBack()
        end(.unavailable)
    }

    /// If Quartz refuses the display's own table, ColorSync restores every display's.
    private func giveBack() {
        guard let base else { return }
        if !gamma.write(base, to: display) { gamma.restoreColorSyncSettings() }
    }

    private func end(_ reason: BrightnessBoostEnd) {
        phase = .ended
        onEnd(reason)
    }
}
