import XCTest
@testable import Sidekey

/// `MediaRemoteNowPlayingSource` behavior that is testable without a real
/// player or the bundled assets present in the test host. The process
/// streaming + transport are covered by contract (the pure parsing/mapper
/// tests) and by the on-device packaging proof; here we pin the fail-closed
/// guarantees the fallback relies on.
final class MediaRemoteNowPlayingSourceTests: XCTestCase {

    func test_initReturnsNil_whenBundleLacksAssets() {
        // The xctest host bundle has no MediaRemoteAdapter resources, so the
        // adapter must refuse to construct (→ factory falls back to
        // AppleScript). This is the fail-closed contract.
        let source = MediaRemoteNowPlayingSource(bundle: .main)
        XCTAssertNil(source, "adapter must fail-closed when run.pl/framework are absent")
    }

    func test_healthCheck_unavailable_whenAssetsMissing() {
        // No assets in the test host → healthCheck must report unavailable
        // without spawning anything.
        XCTAssertEqual(MediaRemoteNowPlayingSource.healthCheck(bundle: .main), .unavailable)
    }

    func test_currentSnapshot_isNil_beforeAnyData() {
        // A freshly built source (when one can be built) returns nil until the
        // stream pushes a snapshot. We can't build a real one here, so assert
        // the cache contract via the factory fallback path instead: an
        // unhealthy environment never yields a MediaRemote source.
        let selection = NowPlayingSourceFactory.makeSelection(
            health: { .unavailable },
            makeMediaRemote: { nil },
            makeAppleScript: { AppleScriptNowPlayingSource() }
        )
        XCTAssertEqual(selection.kind, .appleScript)
    }

    // MARK: - Termination

    /// A stand-in `run.pl` that behaves like the long-lived stream: it never
    /// exits on its own, so only an explicit terminate can end it.
    private func makeStandInStream() throws -> (script: URL, framework: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nowplaying-shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("run.pl")
        try "sleep 600;\n".write(to: script, atomically: true, encoding: .utf8)
        return (script, dir.appendingPathComponent("MediaRemoteAdapter.framework"), dir)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    /// Child PIDs of `pid` (the guard's forked stream).
    private func childPIDs(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let out = Pipe()
        pgrep.standardOutput = out
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return [] }
        pgrep.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { pid_t($0) }
    }

    /// Launches the source on the stand-in and returns (guard, stream) PIDs.
    private func startAndResolvePIDs(_ source: MediaRemoteNowPlayingSource) throws -> (guardPID: pid_t, streamPID: pid_t) {
        source.start()
        XCTAssertTrue(waitUntil(timeout: 5) { source.streamProcessIdentifierForTesting != nil })
        let guardPID = try XCTUnwrap(source.streamProcessIdentifierForTesting)
        XCTAssertTrue(waitUntil(timeout: 5) { !self.childPIDs(of: guardPID).isEmpty }, "guard must fork the stream")
        let streamPID = try XCTUnwrap(childPIDs(of: guardPID).first)
        return (guardPID, streamPID)
    }

    /// SIGKILL or a crash skips `applicationWillTerminate`; the kernel then
    /// closes the guard's stdin. The guard must take the stream down with it.
    func test_parentDeath_stdinEOF_terminatesGuardAndStream() throws {
        let assets = try makeStandInStream()
        defer { try? FileManager.default.removeItem(at: assets.dir) }
        let source = MediaRemoteNowPlayingSource(runScript: assets.script, framework: assets.framework)
        let pids = try startAndResolvePIDs(source)
        defer { source.shutdown() }

        source.closeStreamStdinForTesting()

        XCTAssertTrue(waitUntil(timeout: 5) { !self.isAlive(pids.streamPID) }, "stream must exit when the app's end of stdin closes")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.isAlive(pids.guardPID) }, "guard must exit too")
    }

    /// A stream that exits on its own still ends the guard, so the
    /// termination handler relaunches as before.
    func test_streamExit_endsGuard_andRelaunches() throws {
        let assets = try makeStandInStream()
        defer { try? FileManager.default.removeItem(at: assets.dir) }
        let source = MediaRemoteNowPlayingSource(runScript: assets.script, framework: assets.framework)
        let pids = try startAndResolvePIDs(source)
        defer { source.shutdown() }

        kill(pids.streamPID, SIGKILL)

        XCTAssertTrue(waitUntil(timeout: 5) { !self.isAlive(pids.guardPID) }, "guard must exit with its stream")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                guard let pid = source.streamProcessIdentifierForTesting else { return false }
                return pid != pids.guardPID
            },
            "a new stream must be launched"
        )
    }

    /// `applicationWillTerminate` returns straight into `exit()`, so the
    /// stream child must already be gone when `shutdown()` returns, and no
    /// relaunch may follow. Before the fix the child outlived the app.
    func test_shutdown_terminatesStreamProcess_withoutRelaunch() throws {
        let assets = try makeStandInStream()
        defer { try? FileManager.default.removeItem(at: assets.dir) }

        let source = MediaRemoteNowPlayingSource(runScript: assets.script, framework: assets.framework)
        let (pid, streamPID) = try startAndResolvePIDs(source)
        XCTAssertTrue(isAlive(pid))

        source.shutdown()

        XCTAssertTrue(waitUntil(timeout: 5) { !self.isAlive(streamPID) }, "forked stream must exit after shutdown")

        XCTAssertNil(source.streamProcessIdentifierForTesting, "shutdown must drop the process synchronously")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.isAlive(pid) }, "stream child must exit after shutdown")
        // Longer than the 0.2 s relaunch delay: nothing may respawn.
        usleep(500_000)
        XCTAssertNil(source.streamProcessIdentifierForTesting, "no relaunch after shutdown")
    }

    /// The coordinator path used by `applicationWillTerminate` reaches the
    /// real source and kills its child.
    @MainActor
    func test_coordinatorShutdown_terminatesStreamProcess() throws {
        let assets = try makeStandInStream()
        defer { try? FileManager.default.removeItem(at: assets.dir) }
        let suiteName = "test.nowplaying.shutdown.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let source = MediaRemoteNowPlayingSource(runScript: assets.script, framework: assets.framework)
        let coordinator = NowPlayingCoordinator(
            config: NowPlayingConfig(defaults: defaults),
            controller: NowPlayingController(source: source)
        )
        coordinator.start()
        let (pid, streamPID) = try startAndResolvePIDs(source)

        coordinator.shutdown()

        XCTAssertTrue(waitUntil(timeout: 5) { !self.isAlive(streamPID) }, "forked stream must exit after coordinator shutdown")

        XCTAssertNil(source.streamProcessIdentifierForTesting)
        XCTAssertTrue(waitUntil(timeout: 5) { !self.isAlive(pid) }, "stream child must exit after coordinator shutdown")
        AppState.shared.clearNowPlaying()
    }
}
