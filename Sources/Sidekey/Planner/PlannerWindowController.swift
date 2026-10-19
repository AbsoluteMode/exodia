import AppKit
import SwiftUI

enum PlannerSection: String, CaseIterable { case tasks = "To-do", calendar = "Calendar" }

@MainActor
final class PlannerNavigation: ObservableObject {
    @Published var section: PlannerSection = .tasks
    @Published var selectedDay = Date()
    @Published var taskDraft = ""
}

@MainActor
final class PlannerWindowController: NSWindowController {
    static let shared = PlannerWindowController(store: .shared, connections: .shared)
    private let navigation = PlannerNavigation()

    init(store: PlannerStore, connections: CalendarConnections) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Whytap Planner"
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ExodiaPlanner")
        SidekeyWindowChrome.configureHoverOverlayPolicy(window)
        window.contentViewController = NSHostingController(rootView:
            PlannerView(store: store, navigation: navigation, connections: connections))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic initialization only") }

    func show(_ section: PlannerSection) {
        navigation.section = section
        guard let window else { return }
        if !window.isVisible { SidekeyWindowChrome.centerOnMainScreen(window) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
