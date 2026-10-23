import AppKit
import SwiftUI
import Combine

@MainActor
final class MeetingAssistantPanel {
    let model: MeetingAssistantModel
    private var panel: Panel?
    private var observers: [NSObjectProtocol] = []
    private var observation: AnyCancellable?
    private let openSettings: (AIFeature) -> Void
    private let activityChanged: (Bool, Bool) -> Void
    private var protected: Bool

    init(model: MeetingAssistantModel? = nil, protected: Bool? = nil,
         openSettings: @escaping (AIFeature) -> Void, activityChanged: @escaping (Bool, Bool) -> Void) {
        self.model = model ?? MeetingAssistantModel()
        let protected = protected ?? PrivacyPreferences.shared.screenshotProtectionEnabled
        self.protected = protected; self.openSettings = openSettings; self.activityChanged = activityChanged
        self.model.screenshotProtected = protected
        self.model.onChange = { [weak self] in self?.refresh() }
        observation = self.model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        for name in [NSApplication.didChangeScreenParametersNotification, IslandScreenResolver.selectionDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }
    func show() { model.show(); refresh() }
    func close() { model.dismiss(); panel?.orderOut(nil) }
    func setProtection(_ enabled: Bool) {
        guard enabled != protected else { return }
        protected = enabled; model.screenshotProtected = enabled; model.previewScreenshot = nil
        panel?.orderOut(nil); panel?.close(); panel = nil
        refresh()
    }
    private func makePanel() -> Panel {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Whytap"
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = protected ? .none : .readOnly
        panel.isReleasedWhenClosed = false
        let host = Hosting(rootView: MeetingAssistantView(model: model, openSettings: openSettings))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }
    private func refresh() {
        guard model.visible else { panel?.orderOut(nil); activityChanged(model.listening || model.releasingAudio || model.busy != nil, model.editing); return }
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        let visible = IslandScreenResolver.currentVisibleFrame()
        if abs(model.layoutHeight - visible.height) > 1 { model.layoutHeight = visible.height }
        let limit = max(56, min(250, visible.height - model.questionsHeight - 330))
        if abs(model.bodyLimit - limit) > 1 { model.bodyLimit = limit }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 354, height: 160)
        panel.setFrame(NSRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        activityChanged(true, model.editing || model.previewScreenshot != nil)
    }
    private final class Panel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }
    private final class Hosting<Content: View>: NSHostingView<Content> {
        override var needsPanelToBecomeKey: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
