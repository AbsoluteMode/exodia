import Foundation
import SwiftUI

/// Live permission state shared by Settings and runtime permission repair.
@MainActor
final class PermissionsSettingsViewModel: ObservableObject {
    @Published private(set) var snapshot = PermissionsHelper.snapshot()

    private var onComplete: () -> Void
    private var didComplete = false
    /// When `false`, `completeIfReady` is a no-op even when every
    /// required permission is granted. Used by the Settings path so
    /// the view stays on screen showing the All Set state instead of
    /// auto-closing the window.
    let autoComplete: Bool

    init(onComplete: @escaping () -> Void, autoComplete: Bool = true) {
        self.onComplete = onComplete
        self.autoComplete = autoComplete
    }

    func updateOnComplete(_ onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    var allRequiredGranted: Bool {
        snapshot.allRequiredGranted
    }

    var microphoneLabel: String {
        switch snapshot.microphoneStatus {
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not requested"
        @unknown default:
            return "Unknown"
        }
    }

    func refresh() {
        snapshot = PermissionsHelper.snapshot()
        completeIfReady()
    }

    func requestAccessibility() {
        // Stay menu-bar-only — no Dock icon flip. System Settings will
        // take focus on its own; the host window remains a normal app
        // window when the user returns.
        PermissionsHelper.requestAccessibility()
        refresh()
    }

    func requestMicrophone() {
        // Branch on the live status so a denied/restricted user is
        // routed to System Settings instead of silently no-op'ing:
        // `AVCaptureDevice.requestAccess` only surfaces the native
        // prompt while status is `.notDetermined`.
        let status = PermissionsHelper.microphoneStatus()
        switch status {
        case .notDetermined:
            Task { @MainActor in
                _ = await PermissionsHelper.requestMicrophone()
                refresh()
            }
        case .denied, .restricted:
            PermissionsHelper.openMicrophoneSettings()
            refresh()
        case .authorized:
            refresh()
        @unknown default:
            refresh()
        }
    }

    private func completeIfReady() {
        guard autoComplete else { return }
        guard snapshot.allRequiredGranted, !didComplete else { return }
        didComplete = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.onComplete()
        }
    }
}
