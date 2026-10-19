import AVFoundation
import XCTest
@testable import Sidekey

@MainActor
final class PermissionsSettingsViewModelTests: XCTestCase {
    private var originalStatus: DropHotkeyStatus = .unavailable

    override func setUp() {
        super.setUp()
        originalStatus = AppState.shared.dropHotkeyStatus
    }

    override func tearDown() {
        AppState.shared.dropHotkeyStatus = originalStatus
        super.tearDown()
    }

    func testRefreshReconcilesRuntimeAndRetryForcesInstallationWithoutChangingPermissions() {
        var calls: [(Bool, Bool)] = []
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: false, microphoneStatus: .authorized) },
            runtimeRefresh: { calls.append(($0, $1)) })
        model.refresh()
        model.refresh(restartRecoveryPolling: false)
        model.retryDropShortcut()
        XCTAssertEqual(calls.map { $0.0 }, [false, false, true])
        XCTAssertEqual(calls.map { $0.1 }, [true, false, true])
        XCTAssertFalse(model.snapshot.accessibilityGranted)
    }

    func testAllowedPermissionsDoNotClaimReadyUntilShortcutActuallyInstalls() {
        AppState.shared.dropHotkeyStatus = .unavailable
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: true, microphoneStatus: .authorized) },
            runtimeRefresh: { _, _ in })
        XCTAssertFalse(model.allRequiredGranted)
        AppState.shared.dropHotkeyStatus = .shortcutInUse
        XCTAssertEqual(model.dropHotkeyStatus, .shortcutInUse)
        XCTAssertFalse(model.allRequiredGranted)
        AppState.shared.dropHotkeyStatus = .ready
        XCTAssertTrue(model.allRequiredGranted)
    }
}
