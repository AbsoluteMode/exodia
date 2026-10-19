import Darwin
import XCTest
@testable import Sidekey

final class ApplicationInstanceLeaseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exodia-instance-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testOnlyOneOwnerAndCloseOnExec() throws {
        let first = try acquire(pid: 101)
        XCTAssertTrue(first.closesOnExec, "Provider child processes must not inherit the runtime lease")
        guard case .busy(let owner) = try ApplicationInstanceLease.acquire(directory: directory, ownerPID: 202) else {
            return XCTFail("A second flavor must not own the hotkeys")
        }
        XCTAssertEqual(owner, 101)
        first.release()
    }

    func testReleaseIsIdempotentAndLeavesReusableInode() throws {
        let first = try acquire(pid: 101)
        first.release()
        first.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime.lock").path))
        let second = try acquire(pid: 202)
        defer { second.release() }
        guard case .busy(let owner) = try ApplicationInstanceLease.acquire(directory: directory, ownerPID: 303) else {
            return XCTFail("The replacement must own the same lock file")
        }
        XCTAssertEqual(owner, 202)
    }

    func testObjectLifetimeReleasesTheLease() throws {
        var first: ApplicationInstanceLease? = try acquire(pid: 101)
        XCTAssertNotNil(first)
        first = nil
        let second = try acquire(pid: 202)
        second.release()
    }

    func testStaleOwnerMetadataDoesNotBlockLaunchAndPermissionsArePrivate() throws {
        let file = directory.appendingPathComponent("runtime.lock")
        try Data("999999999\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let lease = try acquire(pid: 101)
        defer { lease.release() }
        XCTAssertEqual(try String(contentsOf: file), "101\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLockDoesNotFollowSymlinksOrModifyTheirTarget() throws {
        let target = directory.appendingPathComponent("unrelated.txt")
        try Data("keep me".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("runtime.lock"), withDestinationURL: target
        )
        XCTAssertThrowsError(try ApplicationInstanceLease.acquire(directory: directory, ownerPID: 101))
        XCTAssertEqual(try String(contentsOf: target), "keep me")
    }

    private func acquire(pid: pid_t) throws -> ApplicationInstanceLease {
        switch try ApplicationInstanceLease.acquire(directory: directory, ownerPID: pid) {
        case .acquired(let lease): return lease
        case .busy: throw NSError(domain: "ApplicationInstanceLeaseTests", code: 1)
        }
    }
}

@MainActor
final class ApplicationInstanceCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exodia-coordinator-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testLegacyProdBlocksBetaBeforeStartupAndReleasesLease() throws {
        let legacy = instance(pid: 101, beta: false, aware: false)
        var conflicts: [ApplicationInstanceConflict] = []
        let candidate = coordinator(pid: 202, beta: true, peers: [legacy]) { conflicts.append($0) }
        XCTAssertFalse(candidate.canLaunch())
        XCTAssertEqual(conflicts.first?.existing, legacy)
        XCTAssertEqual(conflicts.first?.reason, .alreadyRunning)
        guard case .acquired(let lease) = try ApplicationInstanceLease.acquire(directory: directory, ownerPID: 303) else {
            return XCTFail("A rejected launch must release its temporary lease")
        }
        lease.release()
    }

    func testLegacyBetaBlocksProdAndReportsActualPath() {
        let legacy = instance(pid: 101, beta: true, aware: false)
        var conflicts: [ApplicationInstanceConflict] = []
        let candidate = coordinator(pid: 202, beta: false, peers: [legacy]) { conflicts.append($0) }
        XCTAssertFalse(candidate.canLaunch())
        XCTAssertEqual(conflicts.first?.existing?.identity.bundlePath, "/tmp/checkout-101/Exodia-Beta-dev.app")
    }

    func testNewContendersElectOneOwnerAcrossFlavorsWithoutMutualRejection() {
        let prod = instance(pid: 101, beta: false, aware: true, finished: false)
        let beta = instance(pid: 202, beta: true, aware: true, finished: false)
        var firstConflicts: [ApplicationInstanceConflict] = []
        var secondConflicts: [ApplicationInstanceConflict] = []
        let first = coordinator(pid: 101, beta: false, peers: [prod, beta]) { firstConflicts.append($0) }
        let second = coordinator(pid: 202, beta: true, peers: [prod, beta]) { secondConflicts.append($0) }
        XCTAssertTrue(first.canLaunch())
        XCTAssertTrue(first.canLaunch(), "Checking the same running coordinator is idempotent")
        withExtendedLifetime(first) { XCTAssertFalse(second.canLaunch()) }
        XCTAssertTrue(firstConflicts.isEmpty)
        XCTAssertEqual(secondConflicts.first?.existing?.processIdentifier, 101)
    }

    func testDifferentBetaWorktreesElectOneOwner() {
        let firstPeer = instance(pid: 101, beta: true, aware: true, finished: false)
        let secondPeer = instance(pid: 202, beta: true, aware: true, finished: false)
        let first = coordinator(pid: 101, beta: true, peers: [secondPeer]) { _ in XCTFail("First should own the lease") }
        var conflicts: [ApplicationInstanceConflict] = []
        let second = coordinator(pid: 202, beta: true, peers: [firstPeer]) { conflicts.append($0) }
        XCTAssertTrue(first.canLaunch())
        withExtendedLifetime(first) { XCTAssertFalse(second.canLaunch()) }
        XCTAssertEqual(conflicts.first?.existing, firstPeer)
    }

    func testRunningProcessIsBlockedEvenIfItsBundleWasReplacedWithAnAwareBuild() {
        let existing = instance(pid: 101, beta: false, aware: true, finished: true)
        var conflicts: [ApplicationInstanceConflict] = []
        let candidate = coordinator(pid: 202, beta: true, peers: [existing]) { conflicts.append($0) }
        XCTAssertFalse(candidate.canLaunch())
        XCTAssertEqual(conflicts.first?.existing, existing)
    }

    func testOwnProcessAndUnrelatedAppsDoNotBlockLaunch() {
        let own = instance(pid: 101, beta: false, aware: false)
        let unrelated = RunningExodiaInstance(processIdentifier: 999, identity: AppBuildIdentity(
            info: ["CFBundleIdentifier": "com.example.editor"],
            bundleURL: URL(fileURLWithPath: "/Applications/Editor.app")
        ))
        let candidate = coordinator(pid: 101, beta: false, peers: [own, unrelated]) { _ in XCTFail("Not a conflict") }
        XCTAssertTrue(candidate.canLaunch())
    }

    func testUnavailableCoordinationFailsClosedWithoutStartingRuntime() throws {
        let file = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        var conflicts: [ApplicationInstanceConflict] = []
        let candidate = ApplicationInstanceCoordinator(
            directory: file, currentPID: 101, identity: instance(pid: 101, beta: false, aware: true).identity,
            runningInstances: { [] }, presentConflict: { conflicts.append($0) }
        )
        XCTAssertFalse(candidate.canLaunch())
        XCTAssertEqual(conflicts.first?.reason, .coordinationUnavailable)
        XCTAssertNil(conflicts.first?.existing)
    }

    private func coordinator(
        pid: pid_t, beta: Bool, peers: [RunningExodiaInstance],
        conflict: @escaping (ApplicationInstanceConflict) -> Void
    ) -> ApplicationInstanceCoordinator {
        ApplicationInstanceCoordinator(
            directory: directory, currentPID: pid,
            identity: instance(pid: pid, beta: beta, aware: true).identity,
            runningInstances: { peers }, presentConflict: conflict
        )
    }

    private func instance(pid: pid_t, beta: Bool, aware: Bool, finished: Bool = true) -> RunningExodiaInstance {
        let app = beta ? "Exodia-Beta-dev.app" : "Exodia.app"
        return RunningExodiaInstance(processIdentifier: pid, identity: AppBuildIdentity(
            info: [
                "CFBundleIdentifier": beta ? "com.rootwise.sidekey.beta" : "com.rootwise.sidekey",
                "CFBundleDisplayName": beta ? "Exodia Beta" : "Exodia",
                "CFBundleShortVersionString": beta ? "0.0.0-dev" : "2.2.13",
                "CFBundleVersion": beta ? "9999" : "1465",
                AppBuildIdentity.instanceLeaseVersionKey: aware ? 1 : 0
            ],
            bundleURL: URL(fileURLWithPath: "/tmp/checkout-\(pid)/\(app)")
        ), hasFinishedLaunching: finished)
    }
}
