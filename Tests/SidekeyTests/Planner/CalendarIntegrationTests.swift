import XCTest
@testable import Sidekey

@MainActor
final class CalendarIntegrationTests: XCTestCase {
    private func info(_ provider: CalendarProvider, approval: Any? = nil) -> [String: Any] {
        var client: [String: Any] = ["clientID": "shared-fixture"]
        if let approval { client["publicAccessApproved"] = approval }
        return ["WhytapCalendarOAuthClients": [provider.rawValue: client]]
    }

    func testPublicGoogleAndZoomRequireExplicitApproval() throws {
        for provider in [CalendarProvider.google, .zoom] {
            let expected: CalendarConnectionReadiness = provider == .google ? .awaitingGoogleVerification : .awaitingZoomPublication
            for approval: Any? in [nil, "false", "TRUE", true, 1] {
                let configuration = try XCTUnwrap(CalendarClientConfiguration.registered(provider, info: info(provider, approval: approval)))
                XCTAssertFalse(configuration.publicAccessApproved)
                XCTAssertEqual(CalendarConnectionReadiness.shared(provider, configuration: configuration), expected)
                XCTAssertEqual(CalendarConnectionReadiness.authorization(provider, clientID: " shared-fixture ",
                    info: info(provider, approval: approval)), expected)
            }
            XCTAssertEqual(CalendarConnectionReadiness.authorization(provider, clientID: "shared-fixture",
                info: info(provider, approval: "true")), .available)
        }
    }

    func testFeatureReadinessSeparatesProviderSetupFromPublicReview() {
        XCTAssertEqual(CalendarConnectionReadiness.shared(.apple, configuration: nil), .available)
        XCTAssertEqual(CalendarConnectionReadiness.shared(.microsoft, configuration: .init(clientID: "fixture")), .available)
        XCTAssertEqual(CalendarConnectionReadiness.shared(.microsoft, configuration: nil), .setupRequired)
        XCTAssertEqual(CalendarConnectionReadiness.shared(.zoom, configuration: nil), .awaitingZoomPublication)
        XCTAssertEqual(CalendarConnectionReadiness.authorization(.google, clientID: "  ", info: info(.google)), .setupRequired)
        // Advanced setup is for a source user's independent native registration.
        XCTAssertEqual(CalendarConnectionReadiness.authorization(.google, clientID: "my-own-fixture", info: info(.google)), .available)
        XCTAssertEqual(CalendarConnectionReadiness.authorization(.zoom, clientID: "my-own-fixture", info: [:]), .available)
    }

    func testUnapprovedSharedClientsNeverOpenBrowserOrReceiveCallback() async throws {
        for provider in [CalendarProvider.google, .zoom] {
            var opened = false
            let browser = CalendarBrowserSignIn(configurationInfo: info(provider)) { _ in opened = true; return true }
            do {
                _ = try await browser.authorize(provider: provider, clientID: "shared-fixture", state: "fixture", verifier: "fixture")
                XCTFail("Public review must gate browser authorization")
            } catch {
                XCTAssertEqual((error as? CalendarConnectionError)?.errorDescription,
                    CalendarConnectionError.publicReviewPending.errorDescription)
            }
            XCTAssertFalse(opened)
        }
    }

    func testConnectionLeaseSerializesSettingsAndPlannerAndReleasesActivity() throws {
        let suite = "test.calendar-connection-lease." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var activity: [Bool] = []
        let connections = CalendarConnections(defaults: defaults, activityChanged: { activity.append($0) })
        XCTAssertTrue(connections.beginConnecting(provider: .microsoft))
        XCTAssertFalse(connections.beginConnecting(provider: .apple))
        XCTAssertEqual(connections.connectingProvider, .microsoft)
        XCTAssertEqual(activity, [true])
        connections.endConnecting()
        XCTAssertFalse(connections.isConnecting)
        XCTAssertTrue(connections.beginConnecting(provider: .apple))
        connections.endConnecting()
        XCTAssertEqual(activity, [true, false, true, false])
        XCTAssertNil(defaults.object(forKey: CalendarAccountSettings.accountsKey))
    }

    func testAccountStorageIssueIsReportedBeforeStartingNewSignIn() async throws {
        let suite = "test.calendar-connection-capacity." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = (0..<64).map { ConnectedCalendarAccount(id: UUID(), provider: .microsoft, label: "Fixture \($0)") }
        defaults.set(try JSONEncoder().encode(accounts), forKey: CalendarAccountSettings.accountsKey)
        let connections = CalendarConnections(defaults: defaults, oauth: CalendarOAuthClient(storage: PlannerMemoryCredentials()))
        XCTAssertNotNil(connections.accountConnectionIssue)
        try await connections.remove(accounts[0])
        XCTAssertNil(connections.accountConnectionIssue)
        defaults.set(Data("invalid fixture".utf8), forKey: CalendarAccountSettings.accountsKey)
        let damaged = CalendarConnections(defaults: defaults)
        XCTAssertNotNil(damaged.accountConnectionIssue)
        XCTAssertEqual(defaults.data(forKey: CalendarAccountSettings.accountsKey), Data("invalid fixture".utf8))
    }

    func testChangingClientIDCannotReuseTheOtherGoogleDesktopSecret() {
        let registered = CalendarClientConfiguration(clientID: "shared-fixture", clientSecret: "shared-desktop-fixture")
        XCTAssertEqual(CalendarClientConfiguration.secretAfterClientIDChange(from: "shared-fixture", to: "own-client",
            currentSecret: "shared-desktop-fixture", registered: registered), "")
        XCTAssertEqual(CalendarClientConfiguration.secretAfterClientIDChange(from: "own-client", to: "other-client",
            currentSecret: "own-desktop-fixture", registered: registered), "")
        XCTAssertEqual(CalendarClientConfiguration.secretAfterClientIDChange(from: "own-client", to: "shared-fixture",
            currentSecret: "own-desktop-fixture", registered: registered), "shared-desktop-fixture")
        XCTAssertEqual(CalendarClientConfiguration.secretAfterClientIDChange(from: "own-client", to: " own-client ",
            currentSecret: "own-desktop-fixture", registered: registered), "own-desktop-fixture")
    }
}
