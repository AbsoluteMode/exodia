import XCTest
@testable import Sidekey

final class GoogleCalendarReviewSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(flag: String? = "1", expiry: String? = "1800003600") -> GoogleCalendarReviewSession {
        var environment: [String: String] = [:]
        environment["WHYTAP_GOOGLE_CALENDAR_REVIEW"] = flag
        environment["WHYTAP_GOOGLE_CALENDAR_REVIEW_UNTIL"] = expiry
        return GoogleCalendarReviewSession(environment: environment, startedAt: start)
    }

    func testRequiresExplicitFlagAndFiniteBoundedFutureDeadline() {
        XCTAssertFalse(GoogleCalendarReviewSession(environment: [:], startedAt: start).isActive(at: start))
        for flag in [nil, "", "true", "0", " 1"] {
            XCTAssertFalse(session(flag: flag).isActive(at: start))
        }
        for expiry in [nil, "", "NaN", "inf", "1800003600.0", "1.8000036e9", " 1800003600",
                       "-1800003600", "1800000000", "1799999999", "1800007201", "999999999999999999999"] {
            XCTAssertFalse(session(expiry: expiry).isActive(at: start), "Invalid expiry: \(expiry ?? "nil")")
        }
        XCTAssertTrue(session().isActive(at: start))
        XCTAssertTrue(session(expiry: "1800007200").isActive(at: start))
    }

    func testDeadlineDoesNotSlideAndRejectsClockRollback() {
        let review = session()
        XCTAssertFalse(review.isActive(at: start.addingTimeInterval(-1)))
        XCTAssertTrue(review.isActive(at: start.addingTimeInterval(3599)))
        XCTAssertFalse(review.isActive(at: start.addingTimeInterval(3600)))
        XCTAssertFalse(review.isActive(at: start.addingTimeInterval(7200)))
        let rejectedAtStartup = session(expiry: "1800010800")
        XCTAssertFalse(rejectedAtStartup.isActive(at: start.addingTimeInterval(5400)),
            "A rejected launch deadline must not become valid on a later Calendar click")
    }
}
