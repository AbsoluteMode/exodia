import XCTest
@testable import Sidekey

/// A Drop take keeps the mode and route it started with, so switching the mode
/// in the island mid-take never moves the take to another provider.
@MainActor
final class DropTakeTests: XCTestCase {
    func test_before_the_first_take_the_mode_is_fast_and_no_route_is_held() {
        let take = DropTake()
        XCTAssertEqual(take.mode, .fast)
        XCTAssertEqual(take.feature, .dropFast)
        XCTAssertNil(take.route)
    }

    func test_begin_latches_mode_and_route() {
        let take = DropTake()
        let fast = FeatureRoute(account: .soniox, model: "stt-rt-v4")
        take.begin(mode: .fast, route: fast)
        XCTAssertEqual(take.mode, .fast)
        XCTAssertEqual(take.feature, .dropFast)
        XCTAssertEqual(take.route, fast)

        let smart = FeatureRoute(account: .deepgram, model: "nova-3")
        take.begin(mode: .smart, route: smart)
        XCTAssertEqual(take.mode, .smart)
        XCTAssertEqual(take.feature, .dropSmart)
        XCTAssertEqual(take.route, smart)
    }

    func test_begin_without_a_route_clears_the_previous_one() {
        let take = DropTake()
        take.begin(mode: .fast, route: FeatureRoute(account: .soniox, model: "stt-rt-v4"))
        take.begin(mode: .smart, route: nil)
        XCTAssertEqual(take.mode, .smart)
        XCTAssertNil(take.route)
    }
}
