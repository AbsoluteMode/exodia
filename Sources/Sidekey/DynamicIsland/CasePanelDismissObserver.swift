import AppKit
import SwiftUI

/// After a system sheet, hover can remain absent until the pointer returns.
/// An outside click must still dismiss the held panel without swallowing it.
struct CasePanelDismissObserver: NSViewRepresentable {
    var enabled: Bool
    var onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onDismiss = onDismiss
        context.coordinator.setEnabled(enabled)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.setEnabled(false)
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onDismiss: () -> Void = {}
        private var local: Any?
        private var global: Any?

        func setEnabled(_ enabled: Bool) {
            if enabled {
                let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
                if local == nil {
                    local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                        self?.clicked()
                        return event
                    }
                }
                if global == nil {
                    global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                        MainActor.assumeIsolated { self?.clicked() }
                    }
                }
            } else {
                if let local { NSEvent.removeMonitor(local) }
                if let global { NSEvent.removeMonitor(global) }
                local = nil
                global = nil
            }
        }

        private func clicked() {
            guard let view, let window = view.window else { return }
            let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if !view.bounds.contains(point) { onDismiss() }
        }
    }
}
