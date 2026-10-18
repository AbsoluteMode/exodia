import AppKit

/// What the meetings list says to the user around a Delete: the question
/// before and the explanation when it did not work. A struct of closures so
/// tests answer without showing a window.
struct MeetingDeletionPrompts {
    var confirm: @MainActor (_ title: String, _ window: NSWindow?) async -> Bool
    var reportFailure: @MainActor (_ title: String, _ window: NSWindow?) async -> Void

    static let system = MeetingDeletionPrompts(
        confirm: { title, window in
            await MeetingDeletionAlerts.confirm(title: title, in: window)
        },
        reportFailure: { title, window in
            await MeetingDeletionAlerts.reportFailure(title: title, in: window)
        }
    )
}

/// The real alerts. Cancel is the default button: a destructive action must
/// never fire from a stray Return.
@MainActor
private enum MeetingDeletionAlerts {
    static func confirm(title: String, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(title)”?"
        alert.informativeText = "The note, the transcript and the saved recording of this meeting will be removed from this Mac. This can’t be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        return await present(alert, in: window) == .alertSecondButtonReturn
    }

    static func reportFailure(title: String, in window: NSWindow?) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t delete “\(title)”"
        alert.informativeText = "The meeting is still in your list. Try again in a moment."
        alert.addButton(withTitle: "OK")
        _ = await present(alert, in: window)
    }

    private static func present(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
