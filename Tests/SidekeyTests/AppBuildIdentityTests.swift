import XCTest
@testable import Sidekey

final class AppBuildIdentityTests: XCTestCase {
    func testProductionIdentityUsesTheActualBundleValues() {
        let identity = AppBuildIdentity(info: [
            "CFBundleIdentifier": "com.rootwise.sidekey", "CFBundleDisplayName": "Exodia",
            "CFBundleShortVersionString": "2.2.13", "CFBundleVersion": "1465",
            "ExodiaSourceRevision": "b112b44a1234567890", "ExodiaInstanceLeaseVersion": 1
        ], bundleURL: URL(fileURLWithPath: "/Applications/Exodia.app"))
        XCTAssertEqual(identity.summary, "Exodia · Production · 2.2.13 (1465)")
        XCTAssertEqual(identity.bundlePath, "/Applications/Exodia.app")
        XCTAssertEqual(identity.shortRevision, "b112b44a1234")
        XCTAssertEqual(identity.settingsTitle, "Exodia Settings")
        XCTAssertEqual(identity.quitActionTitle, "Quit Exodia")
        XCTAssertTrue(identity.usesInstanceLease)
    }

    func testSourceBetaShowsDevelopmentAndItsCheckoutPath() {
        let identity = AppBuildIdentity(info: [
            "CFBundleIdentifier": "com.rootwise.sidekey.beta", "CFBundleName": "Exodia Beta",
            "CFBundleShortVersionString": "0.0.0-dev", "CFBundleVersion": "9999"
        ], bundleURL: URL(fileURLWithPath: "/tmp/checkout/build/Exodia-Beta-dev.app"))
        XCTAssertEqual(identity.channel, "Development")
        XCTAssertEqual(identity.name, "Exodia Beta")
        XCTAssertEqual(identity.settingsTitle, "Exodia Beta Settings")
        XCTAssertEqual(identity.quitActionTitle, "Quit Exodia Beta")
        XCTAssertEqual(identity.bundlePath, "/tmp/checkout/build/Exodia-Beta-dev.app")
        XCTAssertFalse(identity.usesInstanceLease)
    }

    func testPackagedBetaShowsBetaAndLegacyBuildsAreNotLeaseAware() {
        let identity = AppBuildIdentity(info: [
            "CFBundleIdentifier": "com.rootwise.sidekey.beta",
            "CFBundleShortVersionString": "2.2.13", "CFBundleVersion": "1465"
        ], bundleURL: URL(fileURLWithPath: "/Applications/Exodia-Beta.app"))
        XCTAssertEqual(identity.channel, "Beta")
        XCTAssertFalse(identity.usesInstanceLease)
    }
}
