import AVFoundation
import Carbon.HIToolbox
import Combine
import XCTest
@testable import Sidekey

final class DropHotkeyRecoveryTests: XCTestCase {
    private let tapShortcut = HotkeyShortcut.combo(HotkeyTapCombo(keyCode: 50, modifiers: 0, keyTitle: "]"))

    func testTapShortcutCanExplainMissingAccessibilityButHoldAndModifierNeedItToInstall() {
        XCTAssertTrue(DropHotkeyRecovery.canRegister(shortcut: tapShortcut, gesture: .tap, accessibilityGranted: false))
        XCTAssertFalse(DropHotkeyRecovery.canRegister(shortcut: tapShortcut, gesture: .hold, accessibilityGranted: false))
        XCTAssertFalse(DropHotkeyRecovery.canRegister(shortcut: .holdSpace, gesture: .hold, accessibilityGranted: false))
        XCTAssertFalse(DropHotkeyRecovery.canRegister(shortcut: .modifier(.rightOption), gesture: .tap, accessibilityGranted: false))
        XCTAssertTrue(DropHotkeyRecovery.canRegister(shortcut: .holdSpace, gesture: .hold, accessibilityGranted: true))
    }

    func testFailedInstallationCannotBeReadyEvenWithAllPermissions() {
        let snapshot = PermissionsHelper.Snapshot(accessibilityGranted: true, microphoneStatus: .authorized)
        XCTAssertEqual(DropHotkeyRecovery.status(snapshot: snapshot, installed: false, failure: .unavailable), .unavailable)
        XCTAssertEqual(DropHotkeyRecovery.status(snapshot: snapshot, installed: false, failure: .inputMonitoringRequired), .inputMonitoringRequired)
        XCTAssertEqual(DropHotkeyRecovery.status(snapshot: snapshot, installed: true, failure: nil), .ready)
    }

    func testPermissionsAndCarbonCollisionHaveDifferentRecovery() {
        XCTAssertEqual(DropHotkeyRecovery.status(snapshot: .init(accessibilityGranted: false, microphoneStatus: .authorized), installed: true, failure: nil), .accessibilityRequired)
        XCTAssertEqual(DropHotkeyRecovery.status(snapshot: .init(accessibilityGranted: true, microphoneStatus: .denied), installed: true, failure: nil), .microphoneRequired)
        let collision = HotkeyRegistrationError.carbonRegistration(OSStatus(eventHotKeyExistsErr))
        XCTAssertEqual(DropHotkeyRecovery.failure(for: collision, inputMonitoringGranted: false), .shortcutInUse)
        XCTAssertEqual(DropHotkeyRecovery.failure(for: HotkeyRegistrationError.tapUnavailable, inputMonitoringGranted: false), .inputMonitoringRequired)
        XCTAssertEqual(DropHotkeyRecovery.failure(for: HotkeyRegistrationError.tapUnavailable, inputMonitoringGranted: true), .unavailable)
    }

    func testStopAndPendingStopNeverNeedAStartPermission() {
        for route in [DropFlowRoute.stopStreamingSession, .stopRecordingAndTranscribe, .recordPendingStop, .noop] {
            XCTAssertFalse(DropHotkeyRecovery.requiresStartPermission(route))
        }
        for route in [DropFlowRoute.startStreamingSession, .startRecording, .discardFailedTakeAndStart] {
            XCTAssertTrue(DropHotkeyRecovery.requiresStartPermission(route))
        }
    }

    func testRepairPollingStopsAtBoundAndCanStartANewSession() {
        var budget = DropHotkeyRecoveryPollBudget()
        for _ in 0..<120 { XCTAssertTrue(budget.consume()) }
        XCTAssertFalse(budget.consume())
        XCTAssertFalse(budget.consume())
        budget = DropHotkeyRecoveryPollBudget()
        XCTAssertTrue(budget.consume())
    }

    func testQuietRefreshRepairsExternalGrantAndFailedInstallationWithoutAnActivationEdge() {
        XCTAssertEqual(DropHotkeyRecovery.reconcileDecision(installed: false, accessibilityChanged: true,
            forceRebuild: false, rebuildPending: false, captureActive: false), .rebuild)
        // A failed tap / Carbon registration must retry even when AX never changed.
        XCTAssertEqual(DropHotkeyRecovery.reconcileDecision(installed: false, accessibilityChanged: false,
            forceRebuild: false, rebuildPending: false, captureActive: false), .install)
        XCTAssertEqual(DropHotkeyRecovery.reconcileDecision(installed: true, accessibilityChanged: false,
            forceRebuild: false, rebuildPending: false, captureActive: false), .none)
    }

    func testRepairDefersTeardownUntilStopHookIsNoLongerNeeded() {
        XCTAssertEqual(DropHotkeyRecovery.reconcileDecision(installed: true, accessibilityChanged: true,
            forceRebuild: true, rebuildPending: false, captureActive: true), .deferRebuild)
        XCTAssertEqual(DropHotkeyRecovery.reconcileDecision(installed: true, accessibilityChanged: false,
            forceRebuild: false, rebuildPending: true, captureActive: false), .rebuild)
    }

    @MainActor
    func testCaptureEndServicesDeferredRebuildAfterRepairPollingExpires() async {
        let capture = CaptureFixture()
        var pending = true
        var rebuilds = 0
        var budget = DropHotkeyRecoveryPollBudget()
        for _ in 0..<120 { _ = budget.consume() }
        XCTAssertFalse(budget.consume())

        let observer = AppDelegate.observeDropCaptureEnd(capture.$phase.eraseToAnyPublisher(),
            captureIsActive: { capture.phase == .recording || capture.setupInProgress },
            hasPendingRebuild: { pending },
            onCaptureEnded: { rebuilds += 1; pending = false })
        defer { observer.cancel() }

        capture.phase = .recording
        let activeDelivered = expectation(description: "Active phase delivered")
        DispatchQueue.main.async { activeDelivered.fulfill() }
        await fulfillment(of: [activeDelivered], timeout: 1)
        XCTAssertEqual(rebuilds, 0, "An active take keeps its Stop hook")

        capture.phase = .transcribing
        let endedDelivered = expectation(description: "Capture end delivered")
        DispatchQueue.main.async { endedDelivered.fulfill() }
        await fulfillment(of: [endedDelivered], timeout: 1)
        XCTAssertEqual(rebuilds, 1, "Capture end services pending work independently of the expired timer")
        XCTAssertFalse(pending)
        XCTAssertFalse(budget.consume(), "The phase observer must not restart polling")
    }

    @MainActor
    func testCaptureEndObserverWaitsForSetupAndIgnoresStaleEndOfPreviousTake() async {
        let capture = CaptureFixture()
        capture.setupInProgress = true
        var pending = true
        var rebuilds = 0
        let observer = AppDelegate.observeDropCaptureEnd(capture.$phase.eraseToAnyPublisher(),
            captureIsActive: { capture.phase == .recording || capture.setupInProgress },
            hasPendingRebuild: { pending },
            onCaptureEnded: { rebuilds += 1; pending = false })
        defer { observer.cancel() }

        capture.phase = .transcribing
        let setupDelivered = expectation(description: "Setup phase delivered")
        DispatchQueue.main.async { setupDelivered.fulfill() }
        await fulfillment(of: [setupDelivered], timeout: 1)
        XCTAssertEqual(rebuilds, 0)

        capture.setupInProgress = false
        capture.phase = .idle
        capture.phase = .recording // A new take begins before the old end is delivered.
        let staleDelivered = expectation(description: "Stale end delivered")
        DispatchQueue.main.async { staleDelivered.fulfill() }
        await fulfillment(of: [staleDelivered], timeout: 1)
        XCTAssertEqual(rebuilds, 0)

        capture.phase = .transcribing
        let finalDelivered = expectation(description: "Current capture ends")
        DispatchQueue.main.async { finalDelivered.fulfill() }
        await fulfillment(of: [finalDelivered], timeout: 1)
        XCTAssertEqual(rebuilds, 1)
    }

    @MainActor
    private final class CaptureFixture {
        @Published var phase: AppPhase = .recording
        var setupInProgress = false
    }
}
