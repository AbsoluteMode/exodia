import XCTest
@testable import Sidekey

/// `BuildConfig` is a compile-time flavor selector: every facet (bundle ID,
/// keychain service, appcast feed) must move together so a beta and a prod
/// install can coexist on the same machine without sharing state.
final class BuildConfigTests: XCTestCase {
    func testFlavorFacetsChangeTogether() {
        #if BETA
        XCTAssertEqual(BuildConfig.flavor, .beta)
        XCTAssertEqual(BuildConfig.bundleID, "com.rootwise.sidekey.beta")
        XCTAssertEqual(BuildConfig.appcastURL.path, "/AbsoluteMode/exodia/releases/download/beta/appcast.xml")
        #else
        XCTAssertEqual(BuildConfig.flavor, .prod)
        XCTAssertEqual(BuildConfig.bundleID, "com.rootwise.sidekey")
        XCTAssertEqual(BuildConfig.appcastURL.path, "/AbsoluteMode/exodia/releases/latest/download/appcast.xml")
        #endif
        // The keychain service mirrors the bundle ID so flavors never share
        // secrets in the user's login keychain.
        XCTAssertEqual(BuildConfig.keychainService, BuildConfig.bundleID)
    }

    func testAppcastAndLandingURLsAreHTTPS() {
        XCTAssertEqual(BuildConfig.appcastURL.scheme, "https")
        XCTAssertEqual(BuildConfig.landingURL.scheme, "https")
    }

    func testSourceBuildsCannotReceivePackagedUpdates() {
        XCTAssertFalse(BuildConfig.allowsPackagedUpdates(buildVersion: "9999", displayVersion: "0.0.0-dev"))
        XCTAssertFalse(BuildConfig.allowsPackagedUpdates(buildVersion: "9999", displayVersion: "2.2.0"))
        XCTAssertFalse(BuildConfig.allowsPackagedUpdates(buildVersion: "2300", displayVersion: "2.3.0-dev"))
        XCTAssertFalse(BuildConfig.allowsPackagedUpdates(buildVersion: nil, displayVersion: nil))
        XCTAssertTrue(BuildConfig.allowsPackagedUpdates(buildVersion: "2200", displayVersion: "2.2.0"))
    }
}
