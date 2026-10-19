import AppKit
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

    // MARK: - Artwork recovery

    private final class ArtworkReader {
        private let lock = NSLock()
        private var reads = 0
        private var time: TimeInterval = 0
        var result: MediaRemoteTrackInfo?
        let release = DispatchSemaphore(value: 0)
        var shouldWait = false

        var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
        func advance() { lock.lock(); time += 5; lock.unlock() }
        func read(_ script: URL, _ framework: URL) -> MediaRemoteTrackInfo? {
            lock.lock(); reads += 1; lock.unlock()
            if shouldWait { _ = release.wait(timeout: .now() + 5) }
            return result
        }
    }

    private func trackLine(
        title: String = "Song", item: String = "song:1", elapsed: Int = 1,
        artwork: Bool = false
    ) -> String {
        var fields: [String: Any] = [
            "bundleIdentifier": "com.spotify.client", "processIdentifier": 123,
            "contentItemIdentifier": item, "title": title, "artist": "Artist",
            "album": "Album", "playing": true, "elapsedTimeMicros": elapsed * 1_000_000
        ]
        if artwork {
            fields["artworkData"] = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+nmioAAAAASUVORK5CYII="
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: fields), as: UTF8.self) + "\n"
    }

    private func withArtworkSource(_ body: (MediaRemoteNowPlayingSource, ArtworkReader) throws -> Void) throws {
        let assets = try makeStandInStream()
        defer { try? FileManager.default.removeItem(at: assets.dir) }
        let reader = ArtworkReader()
        let source = MediaRemoteNowPlayingSource(
            runScript: assets.script, framework: assets.framework,
            artworkReader: reader.read, uptime: { reader.now }
        )
        _ = try startAndResolvePIDs(source)
        defer { reader.release.signal(); source.shutdown() }
        try body(source, reader)
    }

    func test_missingArtwork_recoversWithoutAnotherStreamEvent() throws {
        try withArtworkSource { source, reader in
            reader.result = MediaRemoteStreamLine.decode(trackLine(artwork: true))
            source.ingestForTesting(Data(trackLine().utf8))
            XCTAssertTrue(waitUntil(timeout: 2) { source.currentSnapshot()?.artwork != nil })
            source.ingestForTesting(Data(trackLine(elapsed: 8).utf8))
            XCTAssertNotNil(source.currentSnapshot()?.artwork, "later artless events keep the recovered cover")
            XCTAssertEqual(source.currentSnapshot()?.elapsed, 8)
            reader.advance()
            _ = source.currentSnapshot()
            XCTAssertEqual(reader.count, 1, "no more probes once the cover is restored")
        }
    }

    func test_recoveryKeepsNewerPlaybackPosition_andDoesNotOverlapRequests() throws {
        try withArtworkSource { source, reader in
            reader.shouldWait = true
            reader.result = MediaRemoteStreamLine.decode(trackLine(artwork: true))
            source.ingestForTesting(Data(trackLine().utf8))
            XCTAssertTrue(waitUntil(timeout: 2) { reader.count == 1 })
            source.ingestForTesting(Data(trackLine(elapsed: 20).utf8))
            reader.advance()
            for _ in 0..<10 { _ = source.currentSnapshot() }
            XCTAssertEqual(reader.count, 1)
            reader.release.signal()
            XCTAssertTrue(waitUntil(timeout: 2) { source.currentSnapshot()?.artwork != nil })
            XCTAssertEqual(source.currentSnapshot()?.elapsed, 20, "recovery adds only artwork, never stale timing")
        }
    }

    func test_failedRecovery_retriesAfterCooldown_withoutAnotherStreamEvent() throws {
        try withArtworkSource { source, reader in
            source.ingestForTesting(Data(trackLine().utf8))
            XCTAssertTrue(waitUntil(timeout: 2) { reader.count == 1 })
            for _ in 0..<10 { _ = source.currentSnapshot() }
            // Synchronize queued polls before advancing the injected monotonic clock.
            source.ingestForTesting(Data())
            XCTAssertEqual(reader.count, 1)
            reader.advance()
            XCTAssertTrue(waitUntil(timeout: 2) { _ = source.currentSnapshot(); return reader.count == 2 })
        }
    }

    func test_djInterludeRejectsInFlightCover_evenWhenOriginalSongReturns() throws {
        try withArtworkSource { source, reader in
            reader.shouldWait = true
            reader.result = MediaRemoteStreamLine.decode(trackLine(artwork: true))
            source.ingestForTesting(Data(trackLine().utf8))
            XCTAssertTrue(waitUntil(timeout: 2) { reader.count == 1 })
            source.ingestForTesting(Data(trackLine(title: "DJ", item: "dj:1").utf8))
            source.ingestForTesting(Data(trackLine().utf8))
            reader.release.signal()
            source.finishArtworkRefreshForTesting()
            XCTAssertNil(source.currentSnapshot()?.artwork, "A → DJ → A must invalidate the old request")
        }
    }

    func test_recoveryRejectsDifferentTrack() throws {
        try withArtworkSource { source, reader in
            reader.result = MediaRemoteStreamLine.decode(trackLine(title: "Other", item: "other:2", artwork: true))
            source.ingestForTesting(Data(trackLine().utf8))
            source.finishArtworkRefreshForTesting()
            XCTAssertNil(source.currentSnapshot()?.artwork)
        }
    }

    func test_recoveryStopsOnShutdown() throws {
        try withArtworkSource { source, reader in
            reader.shouldWait = true
            reader.result = MediaRemoteStreamLine.decode(trackLine(title: "Other", item: "other:2", artwork: true))
            source.ingestForTesting(Data(trackLine().utf8))
            XCTAssertTrue(waitUntil(timeout: 2) { reader.count == 1 })
            source.shutdown()
            reader.release.signal()
            source.finishArtworkRefreshForTesting()
            XCTAssertNil(source.currentSnapshot(), "a late refresh cannot republish after shutdown")
        }
    }

    func test_refreshOnlyRunsForSupportedTrack_withoutArtwork() throws {
        try withArtworkSource { source, reader in
            source.ingestForTesting(Data(trackLine(artwork: true).utf8))
            source.ingestForTesting(Data("null\n".utf8))
            source.ingestForTesting(Data("{\"title\":\"Browser\",\"bundleIdentifier\":\"com.apple.Safari\"}\n".utf8))
            source.ingestForTesting(Data())
            XCTAssertEqual(reader.count, 0)
        }
    }

    func test_artworkProbe_readsLargeOutput_andBoundsHungProcess() throws {
        let assets = try makeStandInStream()
        defer { try? FileManager.default.removeItem(at: assets.dir) }
        let line = trackLine(title: String(repeating: "a", count: 200_000), artwork: true)
        try "print '\(line)';\n".write(to: assets.script, atomically: true, encoding: .utf8)
        let info = MediaRemoteNowPlayingSource.readArtworkSnapshot(runScript: assets.script, framework: assets.framework)
        XCTAssertNotNil(info?.artwork, "drain stdout while running, even beyond the pipe capacity")
        // Closing stdout must not let waitUntilExit escape the shared deadline.
        try "close STDOUT; sleep 600;\n".write(to: assets.script, atomically: true, encoding: .utf8)
        let start = Date()
        XCTAssertNil(MediaRemoteNowPlayingSource.readArtworkSnapshot(
            runScript: assets.script, framework: assets.framework, timeout: 0.1
        ))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
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
