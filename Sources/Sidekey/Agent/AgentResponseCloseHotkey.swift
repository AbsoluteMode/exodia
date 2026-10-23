import AppKit
import os.log

/// Lifecycle adapter for an agent answer close shortcut. Two concrete
/// adapters share it: `CarbonResponseCloseHotkey` (the user-configurable ⌥Q,
/// a Carbon hotkey) and `EscapeCloseEventMonitor` (the fixed bare Escape, a
/// scoped consuming event tap). The owner keeps one instance of each alive
/// across `start()` / `stop()` cycles — `start()` registers the shortcut,
/// `stop()` tears it down. The callback wired via `setOnHotkey` must funnel
/// into the same dismiss path as the close button so panel close is a single
/// source of truth.
@MainActor
protocol AgentResponseCloseHotkeyControlling: AnyObject {
    func setOnHotkey(_ handler: @escaping () -> Void)
    func start() throws
    func stop()
}

/// Production wiring of the answer panel's Option+Q close hotkey on top
/// of `CarbonHotkeyMonitor`. Splits the protocol's `setOnHotkey` /
/// `start()` / `stop()` lifecycle from `CarbonHotkeyMonitor`'s init-time
/// closure capture — the owner constructs the adapter first and wires
/// the callback in once it has a `self` reference, then `start()`s
/// only when the answer surface is visible.
@MainActor
final class CarbonResponseCloseHotkey: AgentResponseCloseHotkeyControlling {
    private let hotkeyPreferences: HotkeyPreferences
    private var monitor: HotkeyShortcutMonitor?
    private var onHotkey: (() -> Void)?

    init(hotkeyPreferences: HotkeyPreferences) {
        self.hotkeyPreferences = hotkeyPreferences
    }

    func setOnHotkey(_ handler: @escaping () -> Void) {
        self.onHotkey = handler
        // If start() already constructed the monitor, tear it down so
        // the next start() rebuilds with the new handler. Callers in
        // this codebase wire the handler BEFORE start(), so this is
        // defensive.
        if let monitor {
            monitor.stop()
        }
        self.monitor = nil
    }

    func start() throws {
        let handler = onHotkey ?? {}
        monitor?.stop()
        let shortcut = hotkeyPreferences.agentCloseShortcut
        let active = HotkeyShortcutMonitor(
            shortcut: shortcut,
            hotKeyIDValue: CarbonHotkeyMonitor.responseCloseHotKeyID,
            onHotkey: handler
        )
        monitor = active
        try active.start()
    }

    func stop() {
        monitor?.stop()
    }
}
