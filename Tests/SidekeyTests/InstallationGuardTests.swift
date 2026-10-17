import XCTest
@testable import Sidekey

final class InstallationGuardTests: XCTestCase {
    func testReadOnlyDiskImageMustBeInstalledBeforeLaunch() {
        XCTAssertTrue(InstallationGuard.requiresInstallation(
            bundleURL: URL(fileURLWithPath: "/Volumes/Exodia/Exodia.app"), volumeIsReadOnly: true))
    }

    func testTranslocatedAppMustBeInstalledEvenWithoutVolumeMetadata() {
        XCTAssertTrue(InstallationGuard.requiresInstallation(
            bundleURL: URL(fileURLWithPath: "/private/var/folders/example/AppTranslocation/random/d/Exodia.app"),
            volumeIsReadOnly: false))
    }

    func testInstalledAndDeveloperCopiesCanLaunch() {
        for path in ["/Applications/Exodia.app", "/Users/example/Applications/Exodia.app",
                     "/Volumes/External/Apps/Exodia.app", "/tmp/build/Exodia-Beta-dev.app"] {
            XCTAssertFalse(InstallationGuard.requiresInstallation(
                bundleURL: URL(fileURLWithPath: path), volumeIsReadOnly: false))
        }
    }

    func testBareExecutableAndTestBundlesAreNotInstallers() {
        XCTAssertFalse(InstallationGuard.requiresInstallation(
            bundleURL: URL(fileURLWithPath: "/tmp/SidekeyPackageTests.xctest"), volumeIsReadOnly: true))
    }
}
