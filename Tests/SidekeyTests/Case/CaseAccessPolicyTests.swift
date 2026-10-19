import XCTest
import WhytapCaseKit
@testable import Sidekey

final class CaseAccessPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)
    private let projectA = UUID()
    private let projectB = UUID()

    private func app(default mode: CaseAccessMode, overrides: [UUID: CaseAccessMode] = [:]) -> CaseAppRegistration {
        CaseAppRegistration(
            id: UUID(), displayName: "Test AI", identity: .executablePath("/x/ai"),
            defaultMode: mode, projectModes: overrides, createdAt: now)
    }

    func test_project_override_beats_default() {
        let a = app(default: .approve, overrides: [projectA: .bypass])
        XCTAssertEqual(CaseAccessPolicy.decideRun(caller: .registered(a), projectID: projectA, grants: CaseTimedGrants(), now: now), .allow)
        XCTAssertEqual(CaseAccessPolicy.decideRun(caller: .registered(a), projectID: projectB, grants: CaseTimedGrants(), now: now), .askApproval)

        let strict = app(default: .bypass, overrides: [projectA: .approve])
        XCTAssertEqual(CaseAccessPolicy.decideRun(caller: .registered(strict), projectID: projectA, grants: CaseTimedGrants(), now: now), .askApproval)
        XCTAssertEqual(CaseAccessPolicy.decideRun(caller: .registered(strict), projectID: projectB, grants: CaseTimedGrants(), now: now), .allow)
    }

    func test_timed_grant_expires_after_minutes() {
        let a = app(default: .approve)
        var grants = CaseTimedGrants()
        grants.grant(appID: a.id, projectID: projectA, until: now.addingTimeInterval(15 * 60))

        func decide(at offset: TimeInterval, project: UUID) -> CaseAccessDecision {
            CaseAccessPolicy.decideRun(caller: .registered(a), projectID: project, grants: grants, now: now.addingTimeInterval(offset))
        }
        XCTAssertEqual(decide(at: 0, project: projectA), .allow)
        XCTAssertEqual(decide(at: 15 * 60 - 1, project: projectA), .allow)
        XCTAssertEqual(decide(at: 15 * 60, project: projectA), .askApproval, "boundary is exclusive")
        XCTAssertEqual(decide(at: 16 * 60, project: projectA), .askApproval)
        XCTAssertEqual(decide(at: 0, project: projectB), .askApproval, "grant is per project")

        let other = app(default: .approve)
        XCTAssertEqual(CaseAccessPolicy.decideRun(caller: .registered(other), projectID: projectA, grants: grants, now: now), .askApproval, "grant is per app")
    }

    func test_grant_in_the_past_never_allows_and_regrant_extends() {
        let a = app(default: .approve)
        var grants = CaseTimedGrants()
        grants.grant(appID: a.id, projectID: projectA, until: now.addingTimeInterval(-1))
        XCTAssertFalse(grants.isGranted(appID: a.id, projectID: projectA, now: now))
        grants.grant(appID: a.id, projectID: projectA, until: now.addingTimeInterval(60))
        XCTAssertTrue(grants.isGranted(appID: a.id, projectID: projectA, now: now))
    }

    func test_grant_does_not_matter_in_bypass_mode() {
        let a = app(default: .bypass)
        XCTAssertEqual(CaseAccessPolicy.decideRun(caller: .registered(a), projectID: projectA, grants: CaseTimedGrants(), now: now), .allow)
    }

    func test_unknown_ai_is_denied_not_asked() {
        let c = CaseCaller.knownUnregisteredAI(name: "Cursor")
        XCTAssertEqual(CaseAccessPolicy.decideList(caller: c), .deny(.unknownAIApp))
        XCTAssertEqual(CaseAccessPolicy.decideRun(caller: c, projectID: projectA, grants: CaseTimedGrants(), now: now), .deny(.unknownAIApp))
    }

    func test_listing_never_asks_approval_for_registered_app() {
        for mode in [CaseAccessMode.approve, .bypass] {
            XCTAssertEqual(CaseAccessPolicy.decideList(caller: .registered(app(default: mode))), .allow)
        }
    }

    func test_human_needs_touch_id() {
        XCTAssertEqual(CaseAccessPolicy.decideList(caller: .human), .askTouchID)
        XCTAssertEqual(CaseAccessPolicy.decideRun(caller: .human, projectID: projectA, grants: CaseTimedGrants(), now: now), .askTouchID)
    }

    func test_human_is_not_helped_by_any_grant() {
        var grants = CaseTimedGrants()
        grants.grant(appID: UUID(), projectID: projectA, until: now.addingTimeInterval(900))
        XCTAssertEqual(CaseAccessPolicy.decideRun(caller: .human, projectID: projectA, grants: grants, now: now), .askTouchID)
    }
}
