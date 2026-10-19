import AppKit
import Combine
import SwiftUI

private final class NotifyHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: NSRect = .zero
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

private struct NotifyPanelRoot: View {
    @ObservedObject var hub: LocalNotificationHub
    let onRect: (CGRect) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let event = hub.current, let deadline = hub.deadline {
                Group {
                    if event.resolvedPresentation == .icon {
                        GeometryReader { geometry in
                            IslandNotificationIcon(event: event, height: geometry.size.height,
                                onTap: { activate(event) }, onDismiss: { dismiss(event) },
                                onHoverChanged: { hover($0, event: event) })
                        }.frame(width: IslandNotificationIconContent.width)
                    } else {
                        IslandNotificationPill(event: event, deadline: deadline,
                            duration: event.resolvedDuration, onTap: { activate(event) },
                            onHoverChanged: { hover($0, event: event) })
                    }
                }
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { onRect(geometry.frame(in: .named("notify-panel"))) }
                            .onChange(of: geometry.frame(in: .named("notify-panel"))) { _, value in onRect(value) }
                    })
                    .padding(.trailing, event.resolvedPresentation == .card ? 8 : 0)
                    .transition(reduceMotion || event.resolvedPresentation == .icon ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity))
                    .id(event.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .coordinateSpace(name: "notify-panel")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: hub.current?.id)
        .ignoresSafeArea()
    }

    private func activate(_ event: LocalNotificationEvent) {
        guard hub.current?.id == event.id else { return }
        if let link = event.link { NSWorkspace.shared.open(link) }
        hub.dismiss()
    }
    private func dismiss(_ event: LocalNotificationEvent) {
        guard hub.current?.id == event.id else { return }
        hub.dismiss()
    }
    private func hover(_ value: Bool, event: LocalNotificationEvent) {
        guard hub.current?.id == event.id else { return }
        hub.setHovered(value)
    }
}

/// A nonactivating card to the left or an icon over the island's right wing.
@MainActor
final class IslandNotificationPanel: NSPanel {
    private static var storage = IslandNotificationPanel(protected: PrivacyPreferences.shared.screenshotProtectionEnabled)
    static var shared: IslandNotificationPanel { storage }
    private let protected: Bool
    private var host: NotifyHostingView<NotifyPanelRoot>!
    private var cancellable: AnyCancellable?
    private var isEnabled = false

    private init(protected: Bool) {
        self.protected = protected
        let frame = IslandFrameLayout.notificationPanelFrame(on: IslandScreenResolver.currentDescriptor())
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear; hasShadow = false; isMovable = false
        hidesOnDeactivate = false; isFloatingPanel = true; ignoresMouseEvents = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        sharingType = protected ? .none : .readOnly
        level = .screenSaver
        let host = NotifyHostingView(rootView: NotifyPanelRoot(hub: .shared, onRect: { _ in }))
        self.host = host
        host.rootView = NotifyPanelRoot(hub: .shared, onRect: { [weak self] rect in
            guard let self else { return }
            self.host.interactiveRect = NSRect(x: rect.minX, y: self.host.isFlipped ? rect.minY : self.host.bounds.height - rect.maxY,
                                               width: rect.width, height: rect.height)
        })
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]; contentView = host
        cancellable = LocalNotificationHub.shared.$current.receive(on: RunLoop.main).sink { [weak self] event in
            guard let self else { return }
            self.ignoresMouseEvents = event == nil
            if event != nil && self.isEnabled { self.reposition(); self.orderFrontRegardless() }
            else if event == nil { self.host.interactiveRect = .zero; self.orderOut(nil) }
        }
        for name in [NSApplication.didChangeScreenParametersNotification, IslandScreenResolver.selectionDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: name, object: nil)
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    func show() { isEnabled = true; reposition(); if LocalNotificationHub.shared.current != nil { orderFrontRegardless() } }
    func hide() { isEnabled = false; orderOut(nil) }
    static func setScreenshotProtectionEnabled(_ enabled: Bool) {
        guard storage.protected != enabled else { return }
        let wasEnabled = storage.isEnabled
        storage.hide(); storage.close(); storage = IslandNotificationPanel(protected: enabled)
        if wasEnabled { storage.show() }
    }
    @objc private func reposition() {
        let screen = IslandScreenResolver.currentDescriptor()
        let frame = LocalNotificationHub.shared.current?.resolvedPresentation == .icon
            ? IslandFrameLayout.notificationIconPanelFrame(on: screen)
            : IslandFrameLayout.notificationPanelFrame(on: screen)
        level = LocalNotificationHub.shared.current?.resolvedPresentation == .icon
            ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1) : .screenSaver
        setFrame(frame, display: true); host.frame = NSRect(origin: .zero, size: frame.size)
    }
}
