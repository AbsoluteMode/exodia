import AppKit
import MetalKit

/// Extra on one display: `GammaBrightnessBoost` scales the display's table into the headroom
/// that `BrightnessHeadroomTrigger` keeps engaged. Ends reach the controller after the
/// current call, never from inside its own.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
final class NativeBrightnessBoost: BrightnessBoost {
    private var engine: GammaBrightnessBoost?
    private var trigger: BrightnessHeadroomTrigger?
    private let workspaceCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    var gammaFactor: Double { engine?.appliedFactor ?? 1 }

    init?(display id: CGDirectDisplayID, onEnd: @escaping (BrightnessBoostEnd) -> Void,
          workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        let engine = GammaBrightnessBoost(display: id, gamma: QuartzDisplayGamma(), headroom: {
            let screen = NSScreen.screens.first { $0.brightnessDisplayID == id }
            return Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        }, onEnd: { reason in
            DispatchQueue.main.async { onEnd(reason) }
        })
        // A trigger failure is already reported asynchronously.
        guard let trigger = BrightnessHeadroomTrigger(display: id, onFailure: { onEnd(.unavailable) },
                                                      check: { engine.tick() }) else { return nil }
        self.engine = engine
        self.trigger = trigger
        self.workspaceCenter = workspaceCenter
        observers = [
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine?.suspend() }
            },
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine?.resume() }
            },
        ]
    }

    func refresh() { trigger?.followScreen() }

    /// The table goes back before the trigger drops the headroom, so white never clips.
    func close() {
        for token in observers { workspaceCenter.removeObserver(token) }
        observers.removeAll()
        engine?.close()
        engine = nil
        trigger?.close()
        trigger = nil
    }
}

/// A click-through 1×1 pt EDR window in the display's top-right corner, where a built-in
/// display's rounded corner hides it, as Vivid places its own (2026-10-19). Its frames keep
/// WindowServer's EDR headroom raised; it composites nothing over the desktop.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
final class BrightnessHeadroomTrigger {
    private let display: CGDirectDisplayID
    private let window: BrightnessTriggerWindow
    private let view: BrightnessMetalView
    private var frames: BrightnessBoostFrameTimer?

    init?(display id: CGDirectDisplayID, onFailure: @escaping () -> Void, check: @escaping @MainActor () -> Void) {
        guard let screen = Self.screen(for: id), let device = MTLCreateSystemDefaultDevice(),
              let view = BrightnessMetalView(device: device, onFailure: onFailure) else { return nil }
        display = id
        self.view = view
        window = BrightnessTriggerWindow(contentRect: Self.frame(on: screen),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        // Above full-screen apps and the menu bar, so nothing hides it.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary,
                                     .stationary, .ignoresCycle]
        window.sharingType = .none
        window.animationBehavior = .none
        window.alphaValue = 0
        view.frame = NSRect(origin: .zero, size: window.frame.size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        // Reveal only a successfully rendered frame.
        view.onFirstFrame = { [weak window] in window?.alphaValue = 1 }
        window.orderFrontRegardless()
        // Without focus, WindowServer keeps the headroom only briefly after the last frame,
        // so frames keep coming while the strip is closed and another app is in front.
        frames = BrightnessBoostFrameTimer(canPresent: { [weak self] in self?.canPresent ?? false },
                                           present: { [weak self] in self?.view.draw() }, check: check)
    }

    private static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.brightnessDisplayID == id }
    }

    private static func frame(on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.maxX - 1, y: screen.frame.maxY - 1, width: 1, height: 1)
    }

    /// A sleeping display does not consume frames; drawing then could wait for a drawable.
    /// Until its first frame the window is transparent, so it keeps trying: four misses report a failure.
    private var canPresent: Bool { view.onFirstFrame != nil || window.occlusionState.contains(.visible) }

    /// Keeps the corner after a resolution or arrangement change.
    func followScreen() {
        guard let screen = Self.screen(for: display) else {
            view.reportFailure()
            return
        }
        let frame = Self.frame(on: screen)
        if window.frame != frame { window.setFrame(frame, display: false) }
    }

    func close() {
        frames?.stop()
        frames = nil
        view.onFirstFrame = nil
        view.isPaused = true
        view.delegate = nil
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = false
        // Ordering out alone can leave the process registered as an EDR client.
        // Detach the surface and close the window to release its HDR resources.
        window.contentView = nil
        window.close()
    }
}

/// Presents the trigger on its own while it exists, independent of the strip, then lets the
/// boost check its table. Without focus, WindowServer keeps a layer's EDR headroom only about
/// 0.8 s after its last frame.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
final class BrightnessBoostFrameTimer {
    /// Five frames a second, as BrightIntosh presents its trigger.
    nonisolated static let interval: TimeInterval = 0.2
    private let canPresent: @MainActor () -> Bool
    private let present: @MainActor () -> Void
    private let check: @MainActor () -> Void
    private let center: NotificationCenter
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Sleeping displays, a sleeping Mac and another user's session take no frames, and the
    /// next drawable would block the main thread up to a second. Extra stays on through all three.
    private static let pauses: [(start: Notification.Name, end: Notification.Name)] = [
        (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
        (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
        (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
    ]
    /// Each pause ends only with its own notification: the displays can still sleep after the Mac wakes.
    private var activePauses: Set<Notification.Name> = []

    init(interval: TimeInterval = BrightnessBoostFrameTimer.interval,
         center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         canPresent: @escaping @MainActor () -> Bool, present: @escaping @MainActor () -> Void,
         check: @escaping @MainActor () -> Void = {}) {
        self.canPresent = canPresent
        self.present = present
        self.check = check
        self.center = center
        for pause in Self.pauses {
            observers.append(center.addObserver(forName: pause.start, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.activePauses.insert(pause.start) }
            })
            observers.append(center.addObserver(forName: pause.end, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.activePauses.remove(pause.start) }
            })
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                // Released without stop(): nothing is left to present.
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.activePauses.isEmpty else { return }
                if self.canPresent() { self.present() }
                // A hidden trigger loses the headroom too, and the table must follow it.
                self.check()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
    }
}

private final class BrightnessTriggerWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BrightnessMetalView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let onFailure: () -> Void
    var onFirstFrame: (() -> Void)?
    private var missedFrames = 0
    private var failed = false

    init?(device: MTLDevice, onFailure: @escaping () -> Void) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.onFailure = onFailure
        super.init(frame: .zero, device: device)
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        // Any white above SDR engages the panel's whole headroom: the former full-screen layer
        // drew 2 and WindowServer still raised the headroom to the panel's 2.67 (2026-10-19).
        clearColor = MTLClearColor(red: 2, green: 2, blue: 2, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
        guard let metalLayer = layer as? CAMetalLayer else { return nil }
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.isOpaque = false
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reports once and never from inside the controller's own call.
    func reportFailure() {
        guard !failed else { return }
        failed = true
        DispatchQueue.main.async { [onFailure] in onFailure() }
    }

    func draw(in view: MTKView) {
        guard let descriptor = currentRenderPassDescriptor, let drawable = currentDrawable else {
            missedFrames += 1
            if missedFrames == 4 { reportFailure() }
            return
        }
        guard let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            reportFailure()
            return
        }
        missedFrames = 0
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.addCompletedHandler { [weak self] result in
            let succeeded = result.status == .completed
            DispatchQueue.main.async {
                guard let self else { return }
                if succeeded {
                    self.onFirstFrame?()
                    self.onFirstFrame = nil
                } else { self.reportFailure() }
            }
        }
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
