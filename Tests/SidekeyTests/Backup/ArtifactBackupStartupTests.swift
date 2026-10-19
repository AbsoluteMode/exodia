import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class ArtifactBackupStartupTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func testEarlyModalReturnsCannotEscapeOrStartAnotherApplyBeforeTheWorkerFinishes() throws {
        let calls = Counter()
        var pumps = 0
        try ArtifactBackupStartup.runAttempt(operation: {
            calls.increment()
            Thread.sleep(forTimeInterval: 0.025)
        }, pump: {
            pumps += 1
            if pumps == 1 {
                do {
                    try ArtifactBackupStartup.runAttempt(operation: { calls.increment() },
                        pump: { XCTFail("a second modal must never start") })
                    XCTFail("a second restore must be refused while the worker is running")
                } catch { XCTAssertEqual(error as? ArtifactBackupError, .applyInProgress) }
            }
            // The first returns represent Escape dismissing the modal early.
            // Later pumps deliver the worker's main-queue completion, with no
            // window, workspace, provider or real credentials involved.
            if pumps > 4 { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002)) }
        })
        XCTAssertGreaterThan(pumps, 4)
        XCTAssertEqual(calls.value, 1)
    }
}
