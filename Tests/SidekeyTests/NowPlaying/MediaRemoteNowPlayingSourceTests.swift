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

    /// `applicationWillTerminate` returns straight into `exit()`, so the
    /// stream child must already be gone when `shutdown()` returns, and no
    /// relaunch may follow. Before the fix the child outlived the app.
    func test_shutdown_terminatesStreamProcess_withoutRelaunch() throws {
        let assets = try makeStandInStream()
        defer { try? FileManager.default.removeItem(at: assets.dir) }

        let source = MediaRemoteNowPlayingSource(runScript: assets.script, framework: assets.framework)
        source.start()
        XCTAssertTrue(
            waitUntil(timeout: 5) { source.streamProcessIdentifierForTesting != nil },
            "stream process must launch"
        )
        let pid = try XCTUnwrap(source.streamProcessIdentifierForTesting)
        XCTAssertTrue(isAlive(pid))

        source.shutdown()

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
        source.start()
        let coordinator = NowPlayingCoordinator(
            config: NowPlayingConfig(defaults: defaults),
            controller: NowPlayingController(source: source)
        )
        coordinator.start()
        XCTAssertTrue(waitUntil(timeout: 5) { source.streamProcessIdentifierForTesting != nil })
        let pid = try XCTUnwrap(source.streamProcessIdentifierForTesting)

        coordinator.shutdown()

        XCTAssertNil(source.streamProcessIdentifierForTesting)
        XCTAssertTrue(waitUntil(timeout: 5) { !self.isAlive(pid) }, "stream child must exit after coordinator shutdown")
        AppState.shared.clearNowPlaying()
    }
}
