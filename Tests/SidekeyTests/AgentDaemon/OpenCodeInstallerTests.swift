import XCTest
@testable import Sidekey

final class OpenCodeInstallerTests: XCTestCase {
    func testRequiresPublishedSHA512IntegrityBeforeExtraction() {
        let integrity = "sha512-m3HSJL1i83hdltRq0+o9czGb+8KJDKra4t/3JRlnPKcjI8PZm6XBHXx6zG4UuMXaDEZjR1wuXDre9G9zvN7AQw=="
        XCTAssertTrue(OpenCodeInstaller.verify(Data("hello".utf8), integrity: integrity))
        XCTAssertFalse(OpenCodeInstaller.verify(Data("changed".utf8), integrity: integrity))
        for invalid in [nil, "", "sha256-abc", "sha512-not-base64", "sha512-aGVsbG8="] {
            XCTAssertFalse(OpenCodeInstaller.verify(Data("hello".utf8), integrity: invalid))
        }
    }

    func testUsesNativeOfficialV2PackagesForBothMacArchitectures() {
        XCTAssertEqual(OpenCodeInstaller.packageName(appleSilicon: true), "@opencode/cli-darwin-arm64")
        XCTAssertEqual(OpenCodeInstaller.packageName(appleSilicon: false), "@opencode/cli-darwin-x64-baseline")
    }

    func testBindsArchiveToExactPackageAndStableRelease() {
        let name = "@opencode/cli-darwin-arm64"
        let url = "https://registry.npmjs.org/@opencode/cli-darwin-arm64/-/cli-darwin-arm64-2.1.1.tgz"
        func package(_ name: String, _ version: String, _ archive: String) -> OpenCodeInstaller.Package {
            .init(name: name, version: version, dist: .init(tarball: archive, integrity: nil))
        }
        XCTAssertEqual(OpenCodeInstaller.archiveURL(package: package(name, "2.1.1", url),
            expectedName: name, version: "2.1.1")?.absoluteString, url)
        for archive in [url.replacingOccurrences(of: "https:", with: "http:"),
                        url.replacingOccurrences(of: "registry.npmjs.org", with: "example.com"),
                        url + "?redirect=1", url.replacingOccurrences(of: "arm64", with: "x64")] {
            XCTAssertNil(OpenCodeInstaller.archiveURL(package: package(name, "2.1.1", archive),
                expectedName: name, version: "2.1.1"))
        }
        XCTAssertNil(OpenCodeInstaller.archiveURL(package: package("@other/cli", "2.1.1", url),
            expectedName: name, version: "2.1.1"))
        for version in ["1.19.3", "2.1.1-beta.1", "opencode v2.1.1", "v2.1.1", "3.0.0"] {
            XCTAssertNil(OpenCodeInstaller.archiveURL(package: package(name, version, url),
                expectedName: name, version: version))
        }
        XCTAssertNil(OpenCodeInstaller.archiveURL(package: package(name, "2.1.2", url),
            expectedName: name, version: "2.1.1"))
    }
}
