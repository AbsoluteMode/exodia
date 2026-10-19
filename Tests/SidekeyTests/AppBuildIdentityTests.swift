import XCTest
@testable import Sidekey

final class AppBuildIdentityTests: XCTestCase {
    func testProductionIdentityUsesTheActualBundleValues() {
        let identity = AppBuildIdentity(info: [
            "CFBundleIdentifier": "com.rootwise.sidekey", "CFBundleDisplayName": "Whytap",
            "CFBundleShortVersionString": "2.2.13", "CFBundleVersion": "1465",
            "ExodiaSourceRevision": "b112b44a1234567890", "ExodiaInstanceLeaseVersion": 1
        ], bundleURL: URL(fileURLWithPath: "/Applications/Whytap.app"))
        XCTAssertEqual(identity.summary, "Whytap · Production · 2.2.13 (1465)")
        XCTAssertEqual(identity.bundlePath, "/Applications/Whytap.app")
        XCTAssertEqual(identity.shortRevision, "b112b44a1234")
        XCTAssertEqual(identity.settingsTitle, "Whytap Settings")
        XCTAssertEqual(identity.quitActionTitle, "Quit Whytap")
        XCTAssertTrue(identity.usesInstanceLease)
    }

    func testSourceBetaShowsDevelopmentAndItsCheckoutPath() {
        let identity = AppBuildIdentity(info: [
            "CFBundleIdentifier": "com.rootwise.sidekey.beta", "CFBundleName": "Whytap Beta",
            "CFBundleShortVersionString": "0.0.0-dev", "CFBundleVersion": "9999"
        ], bundleURL: URL(fileURLWithPath: "/tmp/checkout/build/Whytap-Beta-dev.app"))
        XCTAssertEqual(identity.channel, "Development")
        XCTAssertEqual(identity.name, "Whytap Beta")
        XCTAssertEqual(identity.settingsTitle, "Whytap Beta Settings")
        XCTAssertEqual(identity.quitActionTitle, "Quit Whytap Beta")
        XCTAssertEqual(identity.bundlePath, "/tmp/checkout/build/Whytap-Beta-dev.app")
        XCTAssertFalse(identity.usesInstanceLease)
    }

    func testPackagedBetaShowsBetaAndLegacyBuildsAreNotLeaseAware() {
        let identity = AppBuildIdentity(info: [
            "CFBundleIdentifier": "com.rootwise.sidekey.beta",
            "CFBundleShortVersionString": "2.2.13", "CFBundleVersion": "1465"
        ], bundleURL: URL(fileURLWithPath: "/Applications/Whytap-Beta.app"))
        XCTAssertEqual(identity.channel, "Beta")
        XCTAssertFalse(identity.usesInstanceLease)
    }
}
