import XCTest
@testable import Sidekey

final class MonitorDashboardTests: XCTestCase {
    func testLegacyEasyMonitoringSnapshotAndFreshness() throws {
        let data = Data(#"{"id":"ops","title":"Operations","updatedAt":"2026-10-17T00:00:00Z","widgets":[{"id":"cpu","kind":"metric","title":"CPU","value":"12","unit":"%"}]}"#.utf8)
        let dashboard = try MonitorDashboard.decode(data)
        let timestamp = try XCTUnwrap(dashboard.updatedAt)
        XCTAssertEqual(dashboard.staleAfterSeconds, 60)
        XCTAssertEqual(dashboard.freshness(at: timestamp.addingTimeInterval(20)), .live)
        XCTAssertEqual(dashboard.freshness(at: timestamp.addingTimeInterval(61)), .stale)
        XCTAssertEqual(dashboard.freshness(at: timestamp.addingTimeInterval(-60)), .unknown)
    }

    func testCustomizationKitFixtureHasNoFakeLiveClaim() throws {
        let project = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = project.appendingPathComponent("docs/customization/examples/dashboard.json")
        let dashboard = try MonitorDashboard.decode(Data(contentsOf: file))
        XCTAssertEqual(dashboard.id, "custom-server-status")
        XCTAssertEqual(dashboard.freshness(at: Date()), .unknown)
    }

    func testRejectsDuplicateWidgetsInvalidProgressAndReservedDashboardID() throws {
        for json in [
            #"{"id":"ops","title":"Ops","widgets":[{"id":"cpu","kind":"metric","title":"CPU"},{"id":"cpu","kind":"status","title":"CPU"}]}"#,
            #"{"id":"ops","title":"Ops","widgets":[{"id":"cpu","kind":"progress","title":"CPU","progress":1.2}]}"#,
            #"{"id":"server-status","title":"Ops","widgets":[{"id":"cpu","kind":"metric","title":"CPU"}]}"#
        ] {
            XCTAssertThrowsError(try MonitorDashboard.decode(Data(json.utf8)))
        }
    }

    func testRejectsOversizedSnapshotBeforeDecoding() {
        XCTAssertThrowsError(try MonitorDashboard.decode(Data(repeating: 32, count: 2_000_001)))
    }

    func testServerSourcesRejectPlaintextSecretsAndCommandInjection() {
        for json in [
            #"{"servers":[{"id":"one","name":"One","group":"Team","sshTarget":"server","password":"placeholder"}]}"#,
            #"{"servers":[{"id":"one","name":"One","group":"Team","sshTarget":"-oProxyCommand=anything"}]}"#,
            #"{"servers":[{"id":"one","name":"One","group":"Team","sshTarget":"server; touch file"}]}"#,
            #"{"servers":[{"id":"one","name":"One","group":"Team","sshTarget":"server","doppler":{"project":"servers","config":"dev","prefix":"EXAMPLE"}}]}"#
        ] {
            XCTAssertThrowsError(try MonitorServerConfiguration.decode(Data(json.utf8)))
        }
    }

    func testServerFailureRetainsReadingButNeverCallsItLive() {
        let date = Date()
        var reading = MonitorServerReading(server: MonitorServer(id: "one", name: "One", group: "Team", sshTarget: "example"))
        XCTAssertEqual(reading.status(at: date, staleAfter: 45), "Unavailable")
        reading.metrics = Self.metrics
        reading.observedAt = date
        XCTAssertEqual(reading.status(at: date, staleAfter: 45), "Live")
        reading.refreshFailed = true
        XCTAssertEqual(reading.status(at: date, staleAfter: 45), "Stale")
        reading.refreshFailed = false
        XCTAssertEqual(reading.status(at: date.addingTimeInterval(46), staleAfter: 45), "Stale")
    }

    static let metrics = MonitorServerMetrics(cpuPercent: 20, memoryUsedBytes: 100, memoryTotalBytes: 200,
                                             load1: 0.5, uptimeSeconds: 1_000, gpus: [], gpuState: "not-present")
}

@MainActor
final class MonitorStoreTests: XCTestCase {
    func testReloadDetectsAtomicUpdatesAndReportsMalformedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("dashboards")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ops.json")
        let store = MonitorStore(root: root)
        try Data(#"{"id":"ops","title":"First","widgets":[{"id":"one","kind":"metric","title":"Reading"}]}"#.utf8).write(to: file, options: .atomic)
        store.reloadFiles()
        XCTAssertEqual(store.dashboards.map(\.title), ["First"])
        try Data(#"{"id":"ops","title":"Updated","widgets":[{"id":"one","kind":"metric","title":"Reading"}]}"#.utf8).write(to: file, options: .atomic)
        store.reloadFiles()
        XCTAssertEqual(store.dashboards.map(\.title), ["Updated"])
        try Data("{".utf8).write(to: directory.appendingPathComponent("broken.json"))
        store.reloadFiles()
        XCTAssertEqual(store.dashboards.count, 1)
        XCTAssertNotNil(store.dashboardError)
    }

    func testSymlinkDashboardIsNotRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("dashboards")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("outside.json")
        try Data(#"{"id":"ops","title":"Outside","widgets":[{"id":"one","kind":"metric","title":"Reading"}]}"#.utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.json"), withDestinationURL: external)
        let store = MonitorStore(root: root)
        store.reloadFiles()
        XCTAssertTrue(store.dashboards.isEmpty)
        XCTAssertNotNil(store.dashboardError)
    }

    func testFailedRefreshKeepsLastGoodMetricsAsStale() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"servers":[{"id":"one","name":"One","group":"Team","sshTarget":"example"}]}"#.utf8)
            .write(to: root.appendingPathComponent("servers.json"))
        let collector = MonitorTestCollector()
        let store = MonitorStore(root: root) { _ in try await collector.collect() }
        store.reloadFiles()
        await store.refreshServers()
        let original = try XCTUnwrap(store.readings.first)
        XCTAssertEqual(original.metrics, MonitorDashboardTests.metrics)
        await store.refreshServers()
        let failed = try XCTUnwrap(store.readings.first)
        XCTAssertEqual(failed.metrics, original.metrics)
        XCTAssertEqual(failed.observedAt, original.observedAt)
        XCTAssertEqual(failed.status(at: Date(), staleAfter: 45), "Stale")
    }

    func testReopenDoesNotPublishResultFromCancelledPollingGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"servers":[{"id":"one","name":"One","group":"Team","sshTarget":"example"}]}"#.utf8)
            .write(to: root.appendingPathComponent("servers.json"))
        let collector = MonitorDeferredCollector()
        let store = MonitorStore(root: root) { _ in await collector.collect() }
        defer { store.stop() }
        store.start()
        for _ in 0..<200 where await collector.pendingCount < 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstPendingCount = await collector.pendingCount
        XCTAssertEqual(firstPendingCount, 1)
        store.stop()
        store.start()
        for _ in 0..<200 where await collector.pendingCount < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let secondPendingCount = await collector.pendingCount
        XCTAssertEqual(secondPendingCount, 2)
        await collector.complete(index: 1, with: MonitorDashboardTests.metrics)
        for _ in 0..<200 where store.readings.first?.metrics == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        var obsolete = MonitorDashboardTests.metrics
        obsolete.cpuPercent = 99
        await collector.complete(index: 0, with: obsolete)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.readings.first?.metrics?.cpuPercent, 20)
    }
}

private actor MonitorTestCollector {
    var calls = 0
    func collect() throws -> MonitorServerMetrics {
        calls += 1
        guard calls == 1 else { throw MonitorProcessError.failed }
        return MonitorDashboardTests.metrics
    }
}

private actor MonitorDeferredCollector {
    var pending: [CheckedContinuation<MonitorServerMetrics, Never>] = []
    var pendingCount: Int { pending.count }

    func collect() async -> MonitorServerMetrics {
        await withCheckedContinuation { pending.append($0) }
    }

    func complete(index: Int, with metrics: MonitorServerMetrics) {
        pending[index].resume(returning: metrics)
    }
}

final class MonitorProcessRunnerTests: XCTestCase {
    func testSubprocessInheritsHomeForCredentialTools() async throws {
        let data = try await MonitorProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/printenv"),
                                                       arguments: ["HOME"])
        XCTAssertEqual(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       ProcessInfo.processInfo.environment["HOME"])
    }

    func testTimeoutTerminatesCollector() async throws {
        do {
            _ = try await MonitorProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                    arguments: ["30"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? MonitorProcessError, .timedOut) }
    }

    func testOutputLimitTerminatesCollector() async throws {
        do {
            _ = try await MonitorProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/yes"),
                                                    arguments: [], timeout: 2)
            XCTFail("Expected output limit")
        } catch { XCTAssertEqual(error as? MonitorProcessError, .outputLimit) }
    }

    func testCancellationTerminatesCollector() async throws {
        let task = Task { try await MonitorProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                              arguments: ["30"]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
