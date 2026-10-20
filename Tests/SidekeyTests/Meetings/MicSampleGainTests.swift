import XCTest
@testable import Sidekey

final class MicSampleGainTests: XCTestCase {
    func testDefaultGainRestoresProductionMicLevelAndClamps() {
        let boosted = MicSampleGain.applyDefault(to: [0.05, -0.2, 0.4, -0.5])

        XCTAssertEqual(boosted, [0.2, -0.8, 1.0, -1.0])
    }

    func testQuietInputKeepsExistingBoostWithoutChangingLength() {
        var processor = MicSampleGainProcessor()
        XCTAssertEqual(processor.process([0.01, -0.02, 0.05]), [0.04, -0.08, 0.2])
        XCTAssertEqual(processor.currentGain, 4)
    }

    func testLoudInputReducesGainBeforeClipping() {
        var processor = MicSampleGainProcessor()
        let result = processor.process([0.1, -0.5, 0.8])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[2], 0.95, accuracy: 0.00001)
        XCTAssertLessThan(abs(result[1]), 0.95)
        XCTAssertLessThan(processor.currentGain, 4)
    }

    func testGainRecoversGraduallyAndAttacksAgainWithoutClipping() {
        var processor = MicSampleGainProcessor()
        _ = processor.process([0.8])
        let limited = processor.currentGain
        _ = processor.process([Float](repeating: 0.01, count: 1600))
        XCTAssertGreaterThan(processor.currentGain, limited)
        XCTAssertLessThan(processor.currentGain, 2, "A 100ms gap must not restore full boost")
        let result = processor.process([-0.9, 0.9])
        XCTAssertEqual(result, [-0.95, 0.95])
    }

    func testInvalidSamplesAndEmptyInputRemainSafe() {
        var processor = MicSampleGainProcessor()
        XCTAssertEqual(processor.process([]), [])
        XCTAssertEqual(processor.process([.nan, .infinity, -.infinity]), [0, 0, 0])
        XCTAssertEqual(processor.currentGain, 4)
    }
}
