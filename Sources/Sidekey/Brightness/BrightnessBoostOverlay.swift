import AppKit
import MetalKit

/// A click-through EDR multiplier over one screen. No screen capture, gamma-table
/// changes or shader compilation. Removing the window removes the multiplier immediately.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
final class BrightnessBoostOverlay: BrightnessOverlay {
    private let window: BrightnessOverlayWindow
    private let view: BrightnessMetalView
    private var multiplier: Double?
    private var frames: BrightnessBoostFrameTimer?

    init?(screen: NSScreen, multiplier: Double, onFailure: @escaping () -> Void) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let view = BrightnessMetalView(device: device, onFailure: onFailure) else { return nil }
        self.view = view
        window = BrightnessOverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        // Above full-screen apps and the menu bar, so the whole display is boosted.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary,
                                     .stationary, .ignoresCycle]
        // Screenshots and screen sharing show the ordinary desktop, not a white multiplier.
        window.sharingType = .none
        window.animationBehavior = .none
        window.alphaValue = 0
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        // Reveal only a successfully rendered frame, avoiding an opaque white flash.
        view.onFirstFrame = { [weak window] in window?.alphaValue = 1 }
        window.orderFrontRegardless()
        // Without focus, WindowServer keeps the boost only briefly after the last frame,
        // so frames keep coming while the strip is closed and another app is in front.
        frames = BrightnessBoostFrameTimer(canPresent: { [weak self] in self?.canPresent ?? false },
                                           present: { [weak self] in self?.view.draw() })
    }

    /// A sleeping display does not consume frames; drawing then could wait for a drawable.
    /// Until its first frame the window is transparent, so it keeps trying: four misses report a failure.
    private var canPresent: Bool { view.onFirstFrame != nil || window.occlusionState.contains(.visible) }

    func update(multiplier next: Double) {
        guard let screen = window.screen else {
            view.reportFailure()
            return
        }
        var changed = next != multiplier
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
            changed = true
        }
        guard changed else { return }
        multiplier = next
        view.clearColor = MTLClearColor(red: next, green: next, blue: next, alpha: 1)
        view.draw()
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

/// Presents the boost on its own while the overlay exists, independent of the strip.
/// Without focus, WindowServer keeps a layer's EDR headroom only about 0.8 s after its last frame.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
final class BrightnessBoostFrameTimer {
    /// Five frames a second, as BrightIntosh presents the same overlay.
    nonisolated static let interval: TimeInterval = 0.2
    private let canPresent: @MainActor () -> Bool
    private let present: @MainActor () -> Void
    private let center: NotificationCenter
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Sleeping displays take no frames, and the next drawable would block the main thread up to a second.
    private var displaysAsleep = false

    init(interval: TimeInterval = BrightnessBoostFrameTimer.interval,
         center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         canPresent: @escaping @MainActor () -> Bool, present: @escaping @MainActor () -> Void) {
        self.canPresent = canPresent
        self.present = present
        self.center = center
        observers = [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)]
            .map { name, asleep in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.displaysAsleep = asleep }
                }
            }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                // Released without stop(): nothing is left to present.
                guard let self else {
                    timer.invalidate()
                    return
                }
                if !self.displaysAsleep, self.canPresent() { self.present() }
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

private final class BrightnessOverlayWindow: NSPanel {
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
        // One uniform pixel stretched over the screen gives the same multiplier
        // without a full-resolution half-float drawable.
        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
        guard let metalLayer = layer as? CAMetalLayer else { return nil }
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.isOpaque = false
        // WindowServer multiplies the underlying desktop by the EDR white.
        // This is an OS-dependent compositing technique, not an Apple brightness API.
        metalLayer.compositingFilter = "multiply"
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
