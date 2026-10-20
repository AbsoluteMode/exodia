import AppKit
import ScreenCaptureKit

@MainActor
final class ScreenshotCapturePanel: NSPanel {
    weak var keyboardCanvas: ScreenshotCanvas?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !(firstResponder is NSTextView), keyboardCanvas?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) { keyboardCanvas?.keyDown(with: event) }
    override func cancelOperation(_ sender: Any?) { keyboardCanvas?.cancelOperation(sender) }
}

/// One in-memory capture session. Files are written only on explicit Download.
@MainActor
final class ScreenshotCoordinator: NSObject, NSSharingServicePickerDelegate {
    private var windows: [ScreenshotCapturePanel] = []
    private var toolbarPanel: ScreenshotCapturePanel?
    private var toolbar: ScreenshotToolbar?
    private weak var selectedCanvas: ScreenshotCanvas?
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private var previousApp: NSRunningApplication?
    private var pins: [NSWindowController] = []
    private var sharePicker: NSSharingServicePicker?
    private var observers: [NSObjectProtocol] = []
    private var outputWidth: Int?
    private var copyWaitReason: String?
    private var copyAfterProcessing = false
    private let activityChanged: (Bool) -> Void
    private let excludedWindowIDs: () -> Set<CGWindowID>
    var isActive: Bool { generation != nil }

    init(activityChanged: @escaping (Bool) -> Void, excludedWindowIDs: @escaping () -> Set<CGWindowID> = { [] }) {
        self.activityChanged = activityChanged; self.excludedWindowIDs = excludedWindowIDs
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(restoreFocus: false) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(restoreFocus: false) }
        })
    }
    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func start() {
        if isActive { cancel(); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        let token = UUID(); generation = token; activityChanged(true); outputWidth = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                    self.cancel(); self.showPermissionHelp(); return
                }
                // Capture before ordering any selection windows. Exclude only the island,
                // not all Whytap windows: the user can also screenshot Settings.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let excluded = self.excludedWindowIDs()
                var snapshots: [(NSScreen, CGImage)] = []
                for screen in NSScreen.screens {
                    guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                          let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                    let config = SCStreamConfiguration()
                    config.width = CGDisplayPixelsWide(id); config.height = CGDisplayPixelsHigh(id)
                    config.showsCursor = false; config.scalesToFit = false
                    let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excluded.contains($0.windowID) })
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    snapshots.append((screen, image))
                }
                guard !snapshots.isEmpty else { throw ScreenshotImageError.rendering }
                guard self.generation == token else { return }
                self.present(snapshots)
            } catch {
                guard self.generation == token else { return }
                self.cancel()
                let alert = NSAlert(); alert.messageText = "Screenshot unavailable"
                alert.informativeText = "Check Screen Recording access for Whytap in System Settings, then try again."
                alert.addButton(withTitle: "OK"); alert.runModal()
            }
        }
    }

    private func showPermissionHelp() {
        let alert = NSAlert(); alert.messageText = "Allow screenshots"
        alert.informativeText = "Enable Whytap in System Settings → Privacy & Security → Screen & System Audio Recording. If macOS asks you to reopen Whytap, finish your current work first."
        alert.addButton(withTitle: "Open System Settings"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    private func present(_ snapshots: [(NSScreen, CGImage)]) {
        for (screen, image) in snapshots {
            let window = ScreenshotCapturePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.level = .screenSaver; window.backgroundColor = .black
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let canvas = ScreenshotCanvas(image: image, size: screen.frame.size)
            window.keyboardCanvas = canvas
            window.contentView = canvas
            canvas.onSelection = { [weak self, weak canvas] in
                guard let self, let canvas, !canvas.selection.isEmpty else { self?.toolbarPanel?.orderOut(nil); return }
                if self.selectedCanvas == nil {
                    self.selectedCanvas = canvas
                    for other in self.windows where other !== canvas.window { other.orderOut(nil) }
                    self.createToolbar(for: canvas)
                }
                self.positionToolbar()
            }
            canvas.onChange = { [weak self] in self?.toolbar?.refresh() }
            canvas.onCommand = { [weak self] command in self?.perform(command) }
            canvas.onBlur = { [weak self, weak canvas] rect, mode in
                guard let canvas else { return }; self?.blur(rect, mode: mode, canvas: canvas)
            }
            windows.append(window); window.orderFrontRegardless()
        }
        let underPointer = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? windows.first
        underPointer?.makeKey(); underPointer?.makeFirstResponder(underPointer?.contentView)
    }

    private func createToolbar(for canvas: ScreenshotCanvas) {
        guard toolbarPanel == nil, let parent = canvas.window else { return }
        let toolbar = ScreenshotToolbar(canvas: canvas)
        let panel = ScreenshotCapturePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .screenSaver; panel.contentView = toolbar
        panel.keyboardCanvas = canvas; panel.hidesOnDeactivate = false
        toolbar.onCommand = { [weak self] command in self?.perform(command) }
        toolbar.onLayout = { [weak self] in self?.positionToolbar() }
        self.toolbar = toolbar; toolbarPanel = panel
        parent.addChildWindow(panel, ordered: .above)
        positionToolbar()
    }

    private func positionToolbar() {
        guard let canvas = selectedCanvas, let parent = canvas.window, let panel = toolbarPanel, let toolbar else { return }
        guard !canvas.selection.isEmpty else { panel.orderOut(nil); return }
        let size = toolbar.fittingSize
        let frame = ScreenshotGeometry.toolbarFrame(selection: parent.convertToScreen(canvas.selection), screen: parent.frame,
                                                     size: CGSize(width: max(430, size.width), height: max(43, size.height)))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func cancel(restoreFocus: Bool = true) {
        generation = nil; task?.cancel(); task = nil
        copyWaitReason = nil; copyAfterProcessing = false
        toolbar?.closeAuxiliaryWindows()
        if let toolbarPanel { toolbarPanel.parent?.removeChildWindow(toolbarPanel); toolbarPanel.orderOut(nil); toolbarPanel.close() }
        toolbarPanel = nil; toolbar = nil; selectedCanvas = nil
        for window in windows { window.orderOut(nil); window.close() }; windows.removeAll()
        sharePicker = nil; activityChanged(false)
        let target = previousApp; previousApp = nil
        if restoreFocus, target?.processIdentifier != ProcessInfo.processInfo.processIdentifier { target?.activate(options: []) }
    }

    private func rawOutput(_ canvas: ScreenshotCanvas) throws -> CGImage {
        try ScreenshotRenderer.image(source: canvas.source, size: canvas.documentSize, annotations: canvas.annotations, crop: canvas.selection)
    }
    private func output(_ canvas: ScreenshotCanvas) throws -> CGImage {
        let image = try rawOutput(canvas)
        return try outputWidth.map { try ScreenshotRenderer.resized(image, width: $0) } ?? image
    }
    private func report(_ text: String, canvas: ScreenshotCanvas) { canvas.message = text; canvas.needsDisplay = true }

    private func blur(_ rect: CGRect, mode: ScreenshotBlurMode, canvas: ScreenshotCanvas) {
        guard !canvas.busy, let token = generation else { return }
        let source = canvas.source, size = canvas.documentSize, annotations = canvas.annotations
        canvas.busyMessage = "Blurring on this Mac… · Return to copy when ready · Esc to cancel"
        canvas.busy = true; copyWaitReason = "Blur"
        task = Task { [weak self, weak canvas] in
            do {
                let worker = Task.detached(priority: .userInitiated) { () throws -> CGImage in
                    try Task.checkCancellation()
                    let image = try ScreenshotRenderer.image(source: source, size: size, annotations: annotations, crop: rect)
                    let boxes: [CGRect]
                    if mode == .textAndNumbers {
                        boxes = try ScreenshotTextDetector.boxes(image)
                        guard !boxes.isEmpty else { throw ScreenshotImageError.noText }
                    } else { boxes = [CGRect(x: 0, y: 0, width: 1, height: 1)] }
                    try Task.checkCancellation()
                    return try ScreenshotRenderer.blurred(image, boxes: boxes)
                }
                let patch = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, let canvas, self.generation == token, !Task.isCancelled else { return }
                canvas.commit(ScreenshotAnnotation(tool: .blur, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], patch: patch))
                canvas.busy = false; self.copyWaitReason = nil
                self.report(mode == .textAndNumbers ? "Text and numbers blurred · Check the result · ⌘Z Undo" : "Area blurred · ⌘Z Undo", canvas: canvas)
                if self.copyAfterProcessing { self.copyAfterProcessing = false; self.perform(.copy) }
            } catch {
                guard let self, let canvas, self.generation == token else { return }
                canvas.busy = false; self.copyWaitReason = nil; self.copyAfterProcessing = false
                self.report(error is ScreenshotImageError ? error.localizedDescription : "Text detection failed. Try Entire area, or try again.", canvas: canvas)
            }
        }
    }

    func perform(_ command: ScreenshotCommand) {
        if case .cancel = command { cancel(); return }
        guard let canvas = selectedCanvas, !canvas.selection.isEmpty else { return }
        if canvas.busy {
            if case .copy = command, let reason = copyWaitReason {
                copyAfterProcessing = true
                canvas.busyMessage = "Copying when \(reason) finishes… · Esc to cancel"
                report(canvas.busyMessage, canvas: canvas)
            }
            return
        }
        do {
            switch command {
            case .copy:
                export(canvas, download: false)
            case .download: export(canvas, download: true)
            case .copyText: try copyText(canvas)
            case .pin:
                let image = try output(canvas)
                showPin(image); cancel()
            case .share:
                guard let toolbar else { return }
                let image = NSImage(cgImage: try output(canvas), size: .zero)
                let picker = NSSharingServicePicker(items: [image]); picker.delegate = self; sharePicker = picker
                picker.show(relativeTo: toolbar.bounds, of: toolbar, preferredEdge: .minY)
            case .resize: try resize(canvas)
            case .cancel: break
            }
        } catch { report(error.localizedDescription, canvas: canvas) }
    }

    private func export(_ canvas: ScreenshotCanvas, download: Bool) {
        guard let token = generation else { return }
        let source = canvas.source, size = canvas.documentSize, annotations = canvas.annotations, crop = canvas.selection
        let width = outputWidth
        canvas.busyMessage = download ? "Downloading to Downloads…" : "Preparing clipboard…"
        copyWaitReason = download ? "Download" : nil
        canvas.busy = true
        task = Task { [weak self, weak canvas] in
            do {
                let worker = Task.detached(priority: .userInitiated) { () throws -> (Data, URL?) in
                    try Task.checkCancellation()
                    let raw = try ScreenshotRenderer.image(source: source, size: size, annotations: annotations, crop: crop)
                    let image = try width.map { try ScreenshotRenderer.resized(raw, width: $0) } ?? raw
                    let bytes = try ScreenshotDownload.png(image)
                    try Task.checkCancellation()
                    let url = try download ? ScreenshotDownload.write(bytes, directory: FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) : nil
                    return (bytes, url)
                }
                let (bytes, url) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, let canvas, self.generation == token, !Task.isCancelled else { return }
                canvas.busy = false; self.copyWaitReason = nil
                if let url {
                    self.report("Downloaded to Downloads as “\(url.lastPathComponent)”", canvas: canvas)
                    NSAccessibility.post(element: canvas, notification: .announcementRequested,
                                         userInfo: [.announcement: canvas.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
                    if self.copyAfterProcessing { self.copyAfterProcessing = false; self.perform(.copy) }
                } else {
                    let board = NSPasteboard.general; board.clearContents()
                    guard board.setData(bytes, forType: .png) else { throw ScreenshotImageError.rendering }
                    self.cancel()
                }
            } catch {
                guard let self, let canvas, self.generation == token else { return }
                canvas.busy = false
                self.copyWaitReason = nil; self.copyAfterProcessing = false
                self.report(download ? "Couldn’t download to Downloads. Check folder access and free space, then try again." : error.localizedDescription, canvas: canvas)
            }
        }
    }

    private func copyText(_ canvas: ScreenshotCanvas) throws {
        let image = try rawOutput(canvas)
        guard let token = generation else { return }
        canvas.busyMessage = "Reading text on this Mac… · Esc to cancel"
        canvas.busy = true
        task = Task { [weak self, weak canvas] in
            do {
                let worker = Task.detached(priority: .userInitiated) { try ScreenshotTextDetector.analyze(image, detectAdditionalBoxes: false).text }
                let text = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, let canvas, self.generation == token, !Task.isCancelled else { return }
                canvas.busy = false
                guard !text.isEmpty else { self.report("No readable text or numbers found.", canvas: canvas); return }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else { throw ScreenshotImageError.rendering }
                self.cancel()
            } catch {
                guard let self, let canvas, self.generation == token else { return }
                canvas.busy = false; self.report("Couldn’t read text and numbers. Try again or copy the image.", canvas: canvas)
            }
        }
    }

    private func resize(_ canvas: ScreenshotCanvas) throws {
        let image = try rawOutput(canvas)
        let alert = NSAlert(); alert.messageText = "Output width in pixels"
        alert.informativeText = "Height follows the original proportions. Copy and Download use PNG."
        let input = NSTextField(string: String(outputWidth ?? image.width)); input.frame.size = CGSize(width: 220, height: 24)
        alert.accessoryView = input; alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        guard let window = canvas.window else { return }
        canvas.busy = true
        alert.beginSheetModal(for: window) { [weak self, weak canvas] result in
            guard let self, let canvas else { return }; canvas.busy = false
            guard self.isActive, result == .alertFirstButtonReturn else { return }
            guard let value = Int(input.stringValue), value >= 1, value <= 16_384,
                  Double(image.height) * Double(value) / Double(image.width) <= 16_384 else {
                self.report("Choose a width from 1 to 16384 pixels, keeping height within 16384.", canvas: canvas); return
            }
            self.outputWidth = value; self.report("Output width: \(value) pixels", canvas: canvas)
        }
    }

    private func showPin(_ image: CGImage) {
        pins.removeAll { $0.window?.isVisible == false }
        let ratio = min(1, 600 / CGFloat(image.width), 420 / CGFloat(image.height))
        let size = CGSize(width: max(100, CGFloat(image.width) * ratio), height: max(60, CGFloat(image.height) * ratio))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating; window.title = "Screenshot"
        let view = NSImageView(image: NSImage(cgImage: image, size: .zero)); view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel("Pinned screenshot"); window.contentView = view
        window.center(); window.orderFrontRegardless(); pins.append(NSWindowController(window: window))
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service != nil { Task { @MainActor [weak self] in self?.cancel() } }
    }
}
