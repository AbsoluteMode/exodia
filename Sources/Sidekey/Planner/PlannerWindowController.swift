import AppKit
import SwiftUI
import Combine

enum PlannerSection: String, CaseIterable { case tasks = "To-do", calendar = "Calendar" }

@MainActor
final class PlannerNavigation: ObservableObject {
    @Published var section: PlannerSection = .tasks
    @Published var selectedDay = Date()
    @Published var taskDraft = ""
    @Published var windowVisible = false
}

@MainActor
final class PlannerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PlannerWindowController(store: .shared, connections: .shared)
    private let navigation = PlannerNavigation()
    private var draftObservation: AnyCancellable?
    private let activityChanged: @MainActor (Bool) -> Void

    init(store: PlannerStore, connections: CalendarConnections,
         activityChanged: (@MainActor (Bool) -> Void)? = nil) {
        self.activityChanged = activityChanged ?? { AppState.shared.plannerActive = $0 }
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
        window.delegate = self
        draftObservation = navigation.$taskDraft.sink { [weak self] draft in
            guard let self else { return }
            self.activityChanged(self.navigation.windowVisible || !draft.isEmpty)
        }
    }

    required init?(coder: NSCoder) { fatalError("Programmatic initialization only") }

    func show(_ section: PlannerSection) {
        guard let window else { return }
        // A tool hotkey must not remove the SwiftUI subtree hosting an editor.
        if window.attachedSheet == nil { navigation.section = section }
        navigation.windowVisible = true
        activityChanged(true)
        if !window.isVisible { SidekeyWindowChrome.centerOnMainScreen(window) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        navigation.windowVisible = false
        activityChanged(!navigation.taskDraft.isEmpty)
    }
}
