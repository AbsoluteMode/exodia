import Darwin
import XCTest
@testable import Sidekey

private final class NotifyOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}

final class NotifyProcessTests: XCTestCase {
    func testOutputDrainsBeforeExitAndArgumentsAreLiteral() async throws {
        let output = NotifyOutputCapture()
        let done = expectation(description: "process completed")
        let process = try NotifyProcess(command: ["/bin/echo", "$(must-not-execute); literal"], environment: ["PATH": "/usr/bin:/bin"],
            onData: { output.append($0) }, onExit: { _ in done.fulfill() })
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(output.text, "$(must-not-execute); literal\n")
        withExtendedLifetime(process) {}
    }
    func testStopKillsProcessGroupIncludingHelpersThatIgnoreTerm() async throws {
        let output = NotifyOutputCapture()
        let done = expectation(description: "group stopped")
        let process = try NotifyProcess(command: ["/bin/sh", "-c", "trap '' TERM; sleep 30 & echo ready; wait"],
            environment: ["PATH": "/usr/bin:/bin"], onData: { output.append($0) }, onExit: { _ in done.fulfill() })
        for _ in 0..<100 where !output.text.contains("ready") { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(output.text.contains("ready"))
        process.stop()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(kill(-process.pid, 0), -1)
    }
    func testMissingExecutableFailsWithoutStartingAWorker() {
        XCTAssertThrowsError(try NotifyProcess(command: ["/no/such/exodia-test-executable"], environment: [:], onData: { _ in }, onExit: { _ in }))
    }
}

@MainActor
final class NotifyScriptSupervisorTests: XCTestCase {
    func testSourceRunsWithoutOpeningDrawerAndDisableStopsPolling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        let script = NotifyScript(id: "synthetic", name: "Synthetic", command: ["/bin/echo", "{\"id\":\"setup\",\"title\":\"Connected\",\"tint\":\"#299FD6\",\"logo\":\"star.fill\"}"], intervalSeconds: 30)
        try JSONEncoder().encode(script).write(to: registry.appendingPathComponent("synthetic.json"))
        let hub = LocalNotificationHub(directory: root)
        let supervisor = NotifyScriptSupervisor(directory: root, hub: hub)
        supervisor.start()
        defer { supervisor.stop() }
        for _ in 0..<200 where hub.history.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(hub.history.first?.id, "synthetic:setup")
        XCTAssertEqual(hub.history.first?.customLogo, "star.fill")
        supervisor.setEnabled(false, id: "synthetic")
        XCTAssertFalse(try JSONDecoder().decode(NotifyScript.self, from: Data(contentsOf: registry.appendingPathComponent("synthetic.json"))).enabled)
        supervisor.remove(id: "synthetic")
        XCTAssertTrue(supervisor.sources.isEmpty)
        XCTAssertEqual(hub.history.count, 1)
    }
}
