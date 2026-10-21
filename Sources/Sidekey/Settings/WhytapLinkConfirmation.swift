// Sources/Sidekey/Settings/WhytapLinkConfirmation.swift
import AppKit

/// Whytap's own dialog for a change proposed by a `whytap://` link. Cancel is
/// the default button (Return cancels), Assign has no key equivalent and
/// stays disabled for a moment, so neither typing nor a click that was meant
/// for the web page can approve it.
/// WHY: .project-docs/decisions/2026-10-21-whytap-link-hotkeys.md
@MainActor
enum WhytapLinkConfirmation {
    static let armingDelay: TimeInterval = 1.0

    /// `true` only when the user clicked Assign.
    static func confirm(_ change: WhytapLinkChange, replacing current: HotkeyShortcut?) -> Bool {
        let alert = makeDialog(change, replacing: current)
        let assign = alert.buttons[1]
        let escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let cancelled = MainActor.assumeIsolated {
                guard event.keyCode == 53, NSApp.modalWindow === alert.window else { return false }
                NSApp.abortModal()
                return true
            }
            return cancelled ? nil : event
        }
        defer { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }
        let timer = Timer(timeInterval: armingDelay, repeats: false) { _ in
            MainActor.assumeIsolated { assign.isEnabled = true }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Builds the real native dialog without displaying or activating it.
    static func makeDialog(_ change: WhytapLinkChange, replacing current: HotkeyShortcut?) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch change {
        case .toolHotkey(let tool, let combo):
            let toolTitle = HoverToolRegistry.info(for: tool).title
            alert.messageText = "Assign \(keys(combo)) to \(toolTitle)?"
            let replaced = current.map { "It replaces \($0.shortcutChipTitles.joined())." }
                ?? "\(toolTitle) has no hotkey now."
            alert.informativeText = "A link asked Whytap to set this hotkey. \(replaced) "
                + "Nothing changes unless you click Assign. You can change it later in Settings -> Hotkeys."
        }
        let cancel = alert.addButton(withTitle: "Cancel")
        let assign = alert.addButton(withTitle: "Assign")
        assign.keyEquivalent = ""
        assign.isEnabled = false
        // A button titled Cancel receives Escape even when added first.
        // Set the Return default explicitly; the modal-local monitor keeps Escape.
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        return alert
    }

    static func showConflict(_ change: WhytapLinkChange, owners: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch change {
        case .toolHotkey(_, let combo):
            alert.messageText = "\(keys(combo)) is already used"
            alert.informativeText = "\(keys(combo)) belongs to \(owners.joined(separator: " and ")). "
                + "A link cannot reassign it; nothing was changed."
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func keys(_ combo: HotkeyTapCombo) -> String {
        combo.shortcutChipTitles.joined()
    }
}
