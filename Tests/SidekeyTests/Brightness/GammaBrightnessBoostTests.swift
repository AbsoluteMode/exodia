import CoreGraphics
import XCTest
@testable import Sidekey

/// Extra scales the display's own transfer table into the EDR headroom that a tiny trigger
/// keeps engaged. A fake table stands in for Quartz: no test changes the real display.
@MainActor
final class GammaBrightnessBoostTests: XCTestCase {
    // MARK: Starting

    func testWaitsForHeadroomBeforeTouchingTheTable() {
        let f = BoostFixture()
        f.headroom = 1
        f.boost.tick()

        XCTAssertEqual(f.gamma.writes, [])
        XCTAssertEqual(f.ends, [])
    }

    func testTheEngagingRiseIsFollowedAtOnce() {
        // WindowServer raised the headroom over about 0.7 s once EDR content appeared (2026-10-19).
        let f = BoostFixture()
        f.headroom = 1.3
        f.boost.tick()
        f.headroom = 1.8
        f.advance(0.2)
        f.headroom = 2.6667
        f.advance(0.2)
        f.advance(0.2)

        XCTAssertEqual(f.gamma.writes, [1.3, 1.8, 2.6667].map {
            .ramp(1).scaled(by: ScreenBrightnessScale.extraGammaFactor(currentHeadroom: $0))
        })
    }

    func testScalesTheDisplaysOwnTableOnceHeadroomIsEngaged() {
        let f = BoostFixture()
        f.headroom = 1
        f.boost.tick()
        f.headroom = 2.6667
        f.advance(0.2)

        XCTAssertEqual(f.gamma.writes, [.ramp(1).scaled(by: 1.45)], "Vivid's factor on the same panel (2026-10-19).")
        XCTAssertEqual(f.ends, [])
    }

    func testNoHeadroomWithinTheTimeoutEndsAsUnavailable() {
        let f = BoostFixture()
        f.headroom = 1
        f.boost.tick()
        f.run(for: GammaBrightnessBoost.engageTimeout - 0.4)
        XCTAssertEqual(f.ends, [])

        f.run(for: 0.6)
        XCTAssertEqual(f.ends, [.unavailable])
        XCTAssertEqual(f.gamma.writes, [])
    }

    func testAnotherBoostersTableIsNeverStacked() {
        // Vivid's own table already ends above SDR white; scaling it again would clip.
        let f = BoostFixture()
        f.gamma.table = .ramp(1.45)
        f.boost.tick()

        XCTAssertEqual(f.ends, [.otherApp])
        XCTAssertEqual(f.gamma.writes, [])
    }

    // MARK: Ending

    func testCloseRestoresTheDisplaysOwnTable() {
        let f = BoostFixture()
        f.boost.tick()
        f.boost.close()

        XCTAssertEqual(f.gamma.writes, [.ramp(1).scaled(by: 1.45), .ramp(1)])
        XCTAssertEqual(f.ends, [], "Switching Extra off is not an end the controller has to report.")
    }

    func testCloseWhileWaitingForHeadroomWritesNothing() {
        let f = BoostFixture()
        f.headroom = 1
        f.boost.tick()
        f.boost.close()
        f.headroom = 2.6667
        f.advance(0.2)

        XCTAssertEqual(f.gamma.writes, [])
        XCTAssertEqual(f.ends, [])
    }

    func testARestoreThatCannotBeWrittenFallsBackToColorSync() {
        let f = BoostFixture()
        f.boost.tick()
        f.gamma.canWrite = false
        f.boost.close()

        XCTAssertEqual(f.gamma.colorSyncRestores, 1)
    }

    func testEndsAreReportedOnce() {
        let f = BoostFixture()
        f.gamma.table = .ramp(1.45)
        f.boost.tick()
        f.advance(0.2)
        f.boost.close()

        XCTAssertEqual(f.ends, [.otherApp])
    }

    // MARK: Keeping the table

    func testASystemResetIsBoostedAgainFromTheNewTable() {
        // A display reconfiguration or a profile change restores the display's own table.
        let f = BoostFixture()
        f.boost.tick()
        f.gamma.table = .ramp(0.9)
        f.advance(0.2)

        XCTAssertEqual(f.gamma.writes.last, .ramp(0.9).scaled(by: 1.45))
        f.boost.close()
        XCTAssertEqual(f.gamma.writes.last, .ramp(0.9), "The newer table is the one to give back.")
        XCTAssertEqual(f.ends, [])
    }

    func testRepeatedResetsEndAsAnotherAppWithoutFightingIt() {
        let f = BoostFixture()
        f.boost.tick()
        for _ in 0..<GammaBrightnessBoost.resetLimit.count {
            f.gamma.table = .ramp(1)
            f.advance(0.2)
        }

        XCTAssertEqual(f.ends, [.otherApp])
        XCTAssertEqual(f.gamma.writes.count, GammaBrightnessBoost.resetLimit.count,
                       "The first boost and each reset but the last.")
        XCTAssertEqual(f.gamma.table, .ramp(1))
    }

    func testResetsFarApartAreEachBoostedAgain() {
        let f = BoostFixture()
        f.boost.tick()
        for _ in 0..<GammaBrightnessBoost.resetLimit.count {
            f.gamma.table = .ramp(1)
            f.advance(GammaBrightnessBoost.resetLimit.interval / 2 + 0.2)
        }

        XCTAssertEqual(f.ends, [])
        XCTAssertEqual(f.gamma.table, .ramp(1).scaled(by: 1.45))
    }

    func testAnotherBoosterTakingOverIsLeftAlone() {
        let f = BoostFixture()
        f.boost.tick()
        f.gamma.table = .ramp(1.6)
        f.advance(0.2)

        XCTAssertEqual(f.ends, [.otherApp])
        XCTAssertEqual(f.gamma.table, .ramp(1.6))
        XCTAssertEqual(f.gamma.writes.count, 1)
    }

    func testAnUnreadableTableEndsAsUnavailable() {
        let f = BoostFixture()
        f.gamma.table = nil
        f.boost.tick()

        XCTAssertEqual(f.ends, [.unavailable])
        XCTAssertEqual(f.gamma.writes, [])
    }

    func testAFailedWriteEndsAsUnavailable() {
        let f = BoostFixture()
        f.gamma.canWrite = false
        f.boost.tick()

        XCTAssertEqual(f.ends, [.unavailable])
        XCTAssertEqual(f.gamma.colorSyncRestores, 0, "Nothing was written, so nothing is given back.")
    }

    func testATableThatTurnsUnreadableIsGivenBack() {
        let f = BoostFixture()
        f.boost.tick()
        f.gamma.table = nil
        f.advance(0.2)

        XCTAssertEqual(f.ends, [.unavailable])
        XCTAssertEqual(f.gamma.writes.last, .ramp(1))
    }

    func testAFailedWriteWhileBoostingFallsBackToColorSync() {
        let f = BoostFixture()
        f.boost.tick()
        f.gamma.canWrite = false
        f.headroom = 1.6
        f.run(for: 2)

        XCTAssertEqual(f.ends, [.unavailable])
        XCTAssertEqual(f.gamma.colorSyncRestores, 1)
    }

    // MARK: Following the headroom

    func testTheFactorFollowsALowerHeadroomOnceItHolds() {
        let f = BoostFixture()
        f.boost.tick()
        f.headroom = 1.6
        f.advance(0.2)
        f.advance(GammaBrightnessBoost.settleInterval - 0.1)
        XCTAssertEqual(f.gamma.writes.count, 1, "A change must hold before the table follows it.")

        f.advance(0.2)
        XCTAssertEqual(f.gamma.writes.last,
                       .ramp(1).scaled(by: ScreenBrightnessScale.extraGammaFactor(currentHeadroom: 1.6)))
    }

    func testABriefHeadroomDipKeepsTheTable() {
        // Stepping the table down and back up for a short dip would itself blink.
        let f = BoostFixture()
        f.boost.tick()
        f.headroom = 1
        f.run(for: GammaBrightnessBoost.settleInterval - 0.4)
        f.headroom = 2.6667
        f.run(for: 3)

        XCTAssertEqual(f.gamma.writes.count, 1)
        XCTAssertEqual(f.ends, [])
    }

    func testTheFactorReturnsWithTheHeadroom() {
        let f = BoostFixture()
        f.boost.tick()
        f.headroom = 1.6
        f.run(for: 2)
        f.headroom = 2.6667
        f.run(for: 2)

        XCTAssertEqual(f.gamma.writes.last, .ramp(1).scaled(by: 1.45))
        XCTAssertEqual(f.ends, [])
    }

    func testLostHeadroomGivesTheTableBackUntilItReturns() {
        // Without headroom the boosted white would clip; only the switch ends Extra.
        let f = BoostFixture()
        f.boost.tick()
        f.headroom = 1
        f.run(for: 30)
        XCTAssertEqual(f.gamma.table, .ramp(1))
        XCTAssertEqual(f.ends, [])

        f.headroom = 2.6667
        f.run(for: 2)
        XCTAssertEqual(f.gamma.table, .ramp(1).scaled(by: 1.45))
        XCTAssertEqual(f.ends, [])
    }

    // MARK: Another session

    func testAnInactiveSessionGetsTheDisplaysOwnTable() {
        // The table belongs to the display, so another user's session would see the boost.
        let f = BoostFixture()
        f.boost.tick()
        f.boost.suspend()
        f.run(for: 1)

        XCTAssertEqual(f.gamma.writes, [.ramp(1).scaled(by: 1.45), .ramp(1)])
        XCTAssertEqual(f.ends, [])
    }

    func testTheSessionReturningBoostsAgain() {
        let f = BoostFixture()
        f.boost.tick()
        f.boost.suspend()
        f.boost.resume()
        f.advance(0.2)

        XCTAssertEqual(f.gamma.writes.last, .ramp(1).scaled(by: 1.45))
        XCTAssertEqual(f.ends, [])
    }

    func testCloseWhileSuspendedWritesNothing() {
        let f = BoostFixture()
        f.boost.tick()
        f.boost.suspend()
        f.boost.close()

        XCTAssertEqual(f.gamma.writes.count, 2)
    }

    // MARK: Factor

    func testTheFactorMatchesVividAndNeverExceedsTheHeadroom() {
        XCTAssertEqual(ScreenBrightnessScale.extraGammaFactor(currentHeadroom: 2.6667), 1.45)
        XCTAssertEqual(ScreenBrightnessScale.extraGammaFactor(currentHeadroom: 16), 1.45)
        XCTAssertEqual(ScreenBrightnessScale.extraGammaFactor(currentHeadroom: 1.6), 1.228, accuracy: 0.001)
        XCTAssertEqual(ScreenBrightnessScale.extraGammaFactor(currentHeadroom: 1), 1)
        XCTAssertEqual(ScreenBrightnessScale.extraGammaFactor(currentHeadroom: 0.5), 1)
        XCTAssertEqual(ScreenBrightnessScale.extraGammaFactor(currentHeadroom: .nan), 1)
        XCTAssertEqual(ScreenBrightnessScale.extraGammaFactor(currentHeadroom: .infinity), 1)

        // The table scales encoded values; sRGB's curve turns the boosted white into light.
        for headroom in stride(from: 1.0, through: 16, by: 0.05) {
            let factor = ScreenBrightnessScale.extraGammaFactor(currentHeadroom: headroom)
            XCTAssertLessThanOrEqual(pow((factor + 0.055) / 1.055, 2.4), headroom + 1e-9, "\(headroom)")
        }
    }
}

/// Display 1 with its own linear table and Vivid's measured headroom; the clock moves only on request.
@MainActor
private final class BoostFixture {
    let gamma = FakeDisplayGamma()
    var headroom = 2.6667
    var now = Date(timeIntervalSince1970: 1_000)
    private(set) var ends: [BrightnessBoostEnd] = []

    lazy var boost = GammaBrightnessBoost(display: 1, gamma: gamma,
                                          headroom: { [unowned self] in self.headroom },
                                          now: { [unowned self] in self.now },
                                          onEnd: { [unowned self] in self.ends.append($0) })

    func advance(_ seconds: TimeInterval) {
        now += seconds
        boost.tick()
    }

    /// The trigger's frames tick every 0.2 s.
    func run(for seconds: TimeInterval) {
        for _ in 0..<Int((seconds / 0.2).rounded()) { advance(0.2) }
    }
}

@MainActor
private final class FakeDisplayGamma: DisplayGammaAccess {
    var table: DisplayGammaTable? = .ramp(1)
    var canWrite = true
    private(set) var writes: [DisplayGammaTable] = []
    private(set) var colorSyncRestores = 0

    func read(_ id: CGDirectDisplayID) -> DisplayGammaTable? { table }

    func write(_ next: DisplayGammaTable, to id: CGDirectDisplayID) -> Bool {
        guard canWrite else { return false }
        writes.append(next)
        table = next
        return true
    }

    func restoreColorSyncSettings() { colorSyncRestores += 1 }
}

private extension DisplayGammaTable {
    /// A linear table ending at `white`.
    static func ramp(_ white: Float) -> DisplayGammaTable {
        let values = (0..<256).map { Float($0) / 255 * white }
        return DisplayGammaTable(red: values, green: values, blue: values)
    }
}
