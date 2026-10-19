import AppKit

/// Native recovery is available even if the normal workspace cannot open.
/// Nothing here constructs AppDelegate or opens a live database.
@MainActor
enum ArtifactBackupStartup {
    static func finishPendingRestore() -> Bool {
        let transaction = ArtifactBackupEnvironment().transaction()
        guard transaction.isArmed || transaction.hasApplyJournal else { return true }
        while true {
            let progress = progressPanel()
            do {
                try ArtifactBackupEngine.applyPendingRestore()
                progress.close()
                return true
            } catch ArtifactBackupError.restoreInterrupted {
                progress.close()
                // The durable rollback succeeded. Settings → Backup explains
                // the interruption without forcing a second app launch.
                return true
            } catch {
                progress.close()
                let alert = NSAlert()
                alert.messageText = "Restore needs attention"
                alert.informativeText = "Your backup and recovery files are kept. Unlock this Mac and check free disk space, then retry. If the restore key is missing, enter your saved recovery code."
                alert.alertStyle = .warning
                let code = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
                code.placeholderString = "Recovery code (only if needed)"
                code.setAccessibilityLabel("Saved backup recovery code")
                alert.accessoryView = code
                alert.addButton(withTitle: "Retry")
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Show Recovery Files")
                let canCancel = !transaction.hasApplyJournal && transaction.isArmed
                if canCancel { alert.addButton(withTitle: "Cancel Restore") }
                let response = alert.runModal()
                if response == .alertSecondButtonReturn { return false }
                if response == .alertThirdButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([ArtifactBackupLocations.production.pendingRestoreRoot])
                    continue
                }
                if canCancel && response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 {
                    do { _ = try transaction.cancelPlanned(); return true }
                    catch { continue }
                }
                if !code.stringValue.isEmpty {
                    do {
                        let key = try ConfigBackupArchive.key(from: code.stringValue)
                        code.stringValue = ""
                        try transaction.unlockPending(with: key)
                    } catch {
                        code.stringValue = ""
                        let invalid = NSAlert()
                        invalid.messageText = "The restore could not be unlocked"
                        invalid.informativeText = "Check that this recovery code belongs to the selected backup and that the Mac is unlocked. Your saved files were kept."
                        invalid.addButton(withTitle: "OK")
                        invalid.runModal()
                    }
                }
            }
        }
    }

    private static func progressPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 138),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Exodia · Restore"
        panel.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Restoring your workspace…")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 64, y: 82, width: 350, height: 22)
        let detail = NSTextField(wrappingLabelWithString: "Your previous data is kept for recovery.\nKeep Exodia open until this finishes.")
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)
        detail.frame = NSRect(x: 64, y: 32, width: 350, height: 42)
        let spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 80, width: 24, height: 24))
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.usesThreadedAnimation = true
        spinner.startAnimation(nil)
        panel.contentView?.addSubview(title)
        panel.contentView?.addSubview(detail)
        panel.contentView?.addSubview(spinner)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.displayIfNeeded()
        return panel
    }
}
