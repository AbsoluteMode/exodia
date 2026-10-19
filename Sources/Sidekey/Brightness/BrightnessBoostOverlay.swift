import AppKit
import MetalKit

/// A click-through EDR multiplier over one screen. No screen capture, gamma-table
/// changes or shader compilation. Removing the window removes the multiplier immediately.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
final class BrightnessBoostOverlay: BrightnessOverlay {
    /// Redraw an unchanged multiplier at most this often, only while the window is visible.
    private static let keepAliveInterval: TimeInterval = 2
    private let window: BrightnessOverlayWindow
    private let view: BrightnessMetalView
    private var multiplier: Double?
    private var lastDraw: Date?

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
    }

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
        let stale = lastDraw.map { Date().timeIntervalSince($0) >= Self.keepAliveInterval } ?? true
        // A sleeping display does not consume frames; drawing then could wait for a drawable.
        guard changed || (stale && window.occlusionState.contains(.visible)) else { return }
        multiplier = next
        lastDraw = Date()
        view.clearColor = MTLClearColor(red: next, green: next, blue: next, alpha: 1)
        view.draw()
    }

    func close() {
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
