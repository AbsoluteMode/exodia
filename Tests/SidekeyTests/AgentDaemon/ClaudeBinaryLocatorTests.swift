import Darwin
import XCTest
@testable import Sidekey

final class ClaudeBinaryLocatorTests: XCTestCase {
    func testPicksFirstExistingKnownPath() {
        let existing = "/opt/homebrew/bin/claude"
        let locator = ClaudeBinaryLocator(fileExists: { $0 == existing }, loginShellWhich: { nil })
        XCTAssertEqual(locator.locate()?.path, existing)
    }

    func testFallsBackToLoginShellWhich() {
        let locator = ClaudeBinaryLocator(
            fileExists: { _ in false },
            loginShellWhich: { "/Users/x/.claude/local/claude" }
        )
        XCTAssertEqual(locator.locate()?.path, "/Users/x/.claude/local/claude")
    }

    func testReturnsNilWhenAbsent() {
        let locator = ClaudeBinaryLocator(fileExists: { _ in false }, loginShellWhich: { nil })
        XCTAssertNil(locator.locate())
    }

    // MARK: - Newest-version selection

    private typealias SemVer = ClaudeBinaryLocator.SemVer

    func testParseSemVer() {
        XCTAssertEqual(ClaudeBinaryLocator.parseSemVer("2.1.160 (Claude Code)"),
                       SemVer(major: 2, minor: 1, patch: 160))
        XCTAssertEqual(ClaudeBinaryLocator.parseSemVer("2.1.69"),
                       SemVer(major: 2, minor: 1, patch: 69))
        XCTAssertNil(ClaudeBinaryLocator.parseSemVer("notaversion"))
    }

    func testSemVerOrdering() {
        XCTAssertTrue(SemVer(major: 2, minor: 1, patch: 152) < SemVer(major: 2, minor: 1, patch: 160))
        XCTAssertTrue(SemVer(major: 2, minor: 1, patch: 69) < SemVer(major: 2, minor: 1, patch: 152))
        XCTAssertTrue(SemVer(major: 2, minor: 1, patch: 100) < SemVer(major: 2, minor: 5, patch: 0))
    }

    func testPicksNewestDesktopManagedVersion() {
        var loc = ClaudeBinaryLocator()
        let root = loc.desktopManagedDir
        loc.listDirectory = { dir in
            dir == root ? ["2.1.155", "2.1.160", "junk"] : []
        }
        loc.fileExists = { _ in true }
        loc.loginShellWhich = { nil }
        loc.versionOf = { _ in nil }
        XCTAssertEqual(
            loc.locate()?.path,
            "\(root)/2.1.160/claude.app/Contents/MacOS/claude")
    }

    func testLegacyWinsWhenStrictlyNewerThanDesktop() {
        var loc = ClaudeBinaryLocator()
        let root = loc.desktopManagedDir
        loc.listDirectory = { dir in
            dir == root ? ["2.1.100"] : []
        }
        loc.fileExists = { $0.contains("2.1.100") || $0 == "/opt/homebrew/bin/claude" }
        loc.loginShellWhich = { nil }
        loc.versionOf = { _ in "2.5.0 (Claude Code)" }
        XCTAssertEqual(loc.locate()?.path, "/opt/homebrew/bin/claude")
    }

    func testFallsBackToLegacyWhenNoDesktopManaged() {
        var loc = ClaudeBinaryLocator()
        loc.listDirectory = { _ in [] }
        loc.fileExists = { $0 == "/usr/local/bin/claude" }
        loc.loginShellWhich = { nil }
        loc.versionOf = { _ in nil }
        XCTAssertEqual(loc.locate()?.path, "/usr/local/bin/claude")
    }

    // MARK: - Claude desktop layouts on a temporary home

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    /// Real directory listing and executable checks, limited to the temporary
    /// home: system-wide installs, the login shell and `--version` are not used.
    private func homeLocator(legacyVersion: String? = nil) -> ClaudeBinaryLocator {
        let root = home.path
        return ClaudeBinaryLocator(
            homeDirectory: root,
            fileExists: { $0.hasPrefix(root + "/") && ClaudeBinaryLocator.isExecutableFile($0) },
            versionOf: { _ in legacyVersion },
            loginShellWhich: { nil })
    }

    private func desktopBinary(_ version: String, hash: String? = nil) -> String {
        let parent = hash.map { "\(version)/\($0)" } ?? version
        return "Library/Application Support/Claude/claude-code/\(parent)/claude.app/Contents/MacOS/claude"
    }

    @discardableResult
    private func place(_ relativePath: String, executable: Bool = true) throws -> String {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644],
                                              ofItemAtPath: url.path)
        return url.path
    }

    func testFindsDesktopAppCopyInHashFolder() throws {
        // Current desktop builds: <version>/<hash>/claude.app, nothing else installed.
        let expected = try place(desktopBinary("2.1.304", hash: "6bbba6adc37f"))
        XCTAssertEqual(homeLocator().locate()?.path, expected)
    }

    func testFindsDesktopAppCopyInFlatLayout() throws {
        let expected = try place(desktopBinary("2.1.160"))
        XCTAssertEqual(homeLocator().locate()?.path, expected)
    }

    func testNewestVersionWinsAcrossLayoutsComparedNumerically() throws {
        // Lexically "2.1.99" > "2.1.304" and "9.9.9" > "10.0.0".
        try place(desktopBinary("2.1.99"))
        try place(desktopBinary("2.1.299", hash: "4fa9694b7975"))
        let nested = try place(desktopBinary("2.1.304", hash: "6bbba6adc37f"))
        XCTAssertEqual(homeLocator().newestDesktopManaged()?.version, SemVer(major: 2, minor: 1, patch: 304))
        XCTAssertEqual(homeLocator().locate()?.path, nested)

        try place(desktopBinary("9.9.9", hash: "0123456789ab"))
        let flat = try place(desktopBinary("10.0.0"))
        XCTAssertEqual(homeLocator().locate()?.path, flat)
    }

    func testSeveralHashesOfOneVersionGiveTheSamePickInAnyListingOrder() throws {
        try place(desktopBinary("2.1.304", hash: "aaaaaaaaaaaa"))
        let expected = try place(desktopBinary("2.1.304", hash: "ffffffffffff"))
        try place(desktopBinary("2.1.299", hash: "zzzzzzzzzzzz"))
        var forward = homeLocator()
        forward.listDirectory = { ((try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []).sorted() }
        var reversed = homeLocator()
        reversed.listDirectory = {
            ((try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []).sorted().reversed()
        }
        XCTAssertEqual(forward.locate()?.path, expected)
        XCTAssertEqual(reversed.locate()?.path, expected)
    }

    func testIgnoresDecoysThatAreNotExecutableFiles() throws {
        let expected = try place(desktopBinary("2.1.299", hash: "4fa9694b7975"))
        // Newer, but not executable.
        try place(desktopBinary("2.1.400", hash: "aaaaaaaaaaaa"), executable: false)
        // Newer, but `claude` is a directory (directories pass access(X_OK)).
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(desktopBinary("2.1.500", hash: "bbbbbbbbbbbb")),
            withIntermediateDirectories: true)
        // Newer hash folder without an app, and a non-version folder with one.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Application Support/Claude/claude-code/2.1.600/cccccccccccc"),
            withIntermediateDirectories: true)
        try place("Library/Application Support/Claude/claude-code/latest/claude.app/Contents/MacOS/claude")
        XCTAssertEqual(homeLocator().locate()?.path, expected)
    }

    func testNothingInstalledReturnsNil() throws {
        XCTAssertNil(homeLocator().locate())
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Application Support/Claude/claude-code/2.1.304/6bbba6adc37f"),
            withIntermediateDirectories: true)
        XCTAssertNil(homeLocator().locate())
    }

    func testDesktopCopyBeatsOlderLegacyCLI() throws {
        try place(".claude/local/claude")
        let desktop = try place(desktopBinary("2.1.304", hash: "6bbba6adc37f"))
        XCTAssertEqual(homeLocator(legacyVersion: "2.1.212 (Claude Code)").locate()?.path, desktop)
        let legacy = home.appendingPathComponent(".claude/local/claude").path
        XCTAssertEqual(homeLocator(legacyVersion: "2.2.0 (Claude Code)").locate()?.path, legacy)
    }

    func testSymlinkedLegacyInstallStillCounts() throws {
        // The native installer links ~/.local/bin/claude to a versioned file.
        let target = try place(".local/share/claude/versions/2.1.300")
        let link = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        XCTAssertEqual(homeLocator().locate()?.path, link.path)
    }

    func testExecutableFIFOIsNotAClientBinary() throws {
        let fifo = home.appendingPathComponent(desktopBinary("2.1.900", hash: "not-a-binary"))
        try FileManager.default.createDirectory(at: fifo.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(fifo.path, 0o755), 0)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fifo.path))
        XCTAssertFalse(ClaudeBinaryLocator.isExecutableFile(fifo.path))
        XCTAssertNil(homeLocator().locate())
    }
}
