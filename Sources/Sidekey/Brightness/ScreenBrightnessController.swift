import AppKit
import Darwin

/// Backlight levels are 0...1. Extra brightness multiplies the composited desktop
/// through EDR on top of the current backlight level.
enum ScreenBrightnessScale {
    /// Sustained full-screen range of XDR MacBook Pro panels over their SDR maximum.
    static let maximumExtra = 2.0
    /// A hardware level at or above this counts as the Mac's own maximum.
    static let hardwareMaximum = 0.99

    static func clampedLevel(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(0, value), 1)
    }

    static func extraMultiplier(potentialHeadroom: Double) -> Double {
        guard potentialHeadroom.isFinite else { return 1 }
        return min(maximumExtra, max(1, potentialHeadroom))
    }
}

struct ScreenBrightnessDisplay: Equatable {
    let id: CGDirectDisplayID
    /// `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue`.
    let potentialHeadroom: Double

    var supportsExtra: Bool { potentialHeadroom > 1.01 }
}

@MainActor
protocol BrightnessOverlay: AnyObject {
    func update(multiplier: Double)
    func close()
}

@MainActor
protocol ScreenBrightnessDevice {
    func displays() -> [ScreenBrightnessDisplay]
    func read(_ id: CGDirectDisplayID) -> Double?
    func write(_ level: Double, to id: CGDirectDisplayID) -> Bool
    func makeOverlay(for id: CGDirectDisplayID, multiplier: Double,
                     onFailure: @escaping () -> Void) -> BrightnessOverlay?
}

/// Hover Display: the island display's backlight plus an Extra switch.
/// Extra is a fixed EDR multiplier overlay on top of whatever the backlight is, and it
/// never writes the backlight itself. The slider, the Mac's brightness keys, automatic
/// brightness, idle dimming, closing the strip, sleep and a session switch leave it on.
/// Only the switch ends it, apart from heat, a display change or lost headroom, an
/// overlay failure and quit.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
final class ScreenBrightnessController: ObservableObject {
    static let shared = ScreenBrightnessController()

    /// Each notice fits one status line of the narrowest (310 pt) island.
    static let writeFailedNotice = "Couldn't change this display's brightness."
    static let extraUnavailableNotice = "Extra brightness isn't available right now."
    static let coolingNotice = "Extra is paused while your Mac cools down."
    /// A read right after a write can still report the previous backlight level.
    static let writeSettleInterval: TimeInterval = 0.75

    @Published private(set) var level = 0.0
    @Published private(set) var isExtraOn = false
    @Published private(set) var display: ScreenBrightnessDisplay?
    @Published private(set) var isAvailable = false
    @Published private(set) var notice: String?
    /// Extra is offered next to a working slider only, so an unadjustable display has neither.
    var supportsExtra: Bool { isAvailable && display?.supportsExtra == true }

    private let device: ScreenBrightnessDevice
    private let selectedDisplayID: @MainActor () -> CGDirectDisplayID?
    private let extraAllowed: () -> Bool
    private let now: () -> Date
    private var overlay: BrightnessOverlay?
    private var overlayGeneration = 0
    /// A write settles only on its own display; another display's reading is current.
    private var lastWrite: (display: CGDirectDisplayID, date: Date)?
    private var timer: Timer?
    private var viewers = 0
    /// True while a visible strip follows outside changes.
    var isPolling: Bool { timer != nil }
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(device: ScreenBrightnessDevice? = nil,
         selectedDisplayID: @escaping @MainActor () -> CGDirectDisplayID? = {
             guard let uuid = IslandScreenResolver.currentDescriptor().uuid else { return nil }
             return NSScreen.screens.first { $0.sidekeyDisplayUUID == uuid }?.brightnessDisplayID
         },
         observeSystem: Bool = true,
         center: NotificationCenter = .default,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         extraAllowed: @escaping () -> Bool = {
             let state = ProcessInfo.processInfo.thermalState
             return state != .serious && state != .critical
         },
         now: @escaping () -> Date = Date.init) {
        self.device = device ?? NativeScreenBrightnessDevice()
        self.selectedDisplayID = selectedDisplayID
        self.extraAllowed = extraAllowed
        self.now = now
        guard observeSystem else { return }
        let workspace = workspaceCenter
        observe(center, NSApplication.didChangeScreenParametersNotification) { $0.refresh() }
        observe(center, IslandScreenResolver.selectionDidChangeNotification) { $0.refresh() }
        // Sleep and a session switch leave Extra on; its frames pause meanwhile.
        observe(workspace, NSWorkspace.didWakeNotification) { $0.refresh() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.refresh() }
        observe(center, ProcessInfo.thermalStateDidChangeNotification) { $0.thermalStateDidChange() }
    }

    /// The strip is visible: read the current level and follow outside changes.
    func beginInteraction() {
        viewers += 1
        refresh()
    }

    func endInteraction() {
        viewers = max(0, viewers - 1)
        updatePolling()
    }

    /// Assigns only changed values: `@Published` announces every assignment and
    /// the strip refreshes twice a second.
    func refresh() {
        let displays = device.displays()
        let selectedID = selectedDisplayID()
        let target = displays.first { $0.id == selectedID } ?? displays.first
        if display?.id != target?.id {
            endExtra()
            notice = nil
        }
        if display != target { display = target }
        guard let target, let hardware = device.read(target.id), hardware.isFinite else {
            endExtra()
            if isAvailable { isAvailable = false }
            if level != 0 { level = 0 }
            updatePolling()
            return
        }
        if !isAvailable { isAvailable = true }
        if isExtraOn {
            if target.supportsExtra {
                // A lower backlight here is not a request to end Extra: automatic
                // brightness and idle dimming change it without the user.
                overlay?.update(multiplier: ScreenBrightnessScale.extraMultiplier(
                    potentialHeadroom: target.potentialHeadroom))
            } else {
                endExtra()
            }
        }
        let current = ScreenBrightnessScale.clampedLevel(hardware)
        if !isSettling(target.id), level != current { level = current }
        updatePolling()
    }

    /// The slider. Extra stays on at any level, as with the Mac's own brightness keys.
    func setLevel(_ requested: Double) {
        guard isAvailable, let display else { return }
        let next = ScreenBrightnessScale.clampedLevel(requested)
        guard write(next, to: display.id) else {
            refresh()
            notice = Self.writeFailedNotice
            return
        }
        notice = nil
        level = next
    }

    func setExtra(_ enabled: Bool) {
        if enabled { startExtra() } else { stopExtra() }
    }

    /// Ends Extra; the backlight stays where it is.
    func stopExtra(notice newNotice: String? = nil) {
        endExtra()
        if let newNotice { notice = newNotice }
        refresh()
    }

    /// Thermal pressure pauses an active Extra; with Extra off there is nothing to report.
    func thermalStateDidChange() {
        guard isExtraOn, !extraAllowed() else { return }
        stopExtra(notice: Self.coolingNotice)
    }

    func shutdown() {
        endExtra()
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func startExtra() {
        guard !isExtraOn, isAvailable, let display, display.supportsExtra else { return }
        guard extraAllowed() else {
            notice = Self.coolingNotice
            return
        }
        let multiplier = ScreenBrightnessScale.extraMultiplier(potentialHeadroom: display.potentialHeadroom)
        let generation = overlayGeneration
        guard let created = device.makeOverlay(for: display.id, multiplier: multiplier, onFailure: { [weak self] in
            // A late failure from a closed overlay must not end a newer Extra.
            guard let self, self.overlayGeneration == generation else { return }
            self.stopExtra(notice: Self.extraUnavailableNotice)
        }) else {
            notice = Self.extraUnavailableNotice
            return
        }
        overlay = created
        isExtraOn = true
        notice = nil
        created.update(multiplier: multiplier)
        updatePolling()
    }

    private func endExtra() {
        overlayGeneration += 1
        overlay?.close()
        overlay = nil
        guard isExtraOn else { return }
        isExtraOn = false
        updatePolling()
    }

    private func write(_ value: Double, to id: CGDirectDisplayID) -> Bool {
        guard device.write(value, to: id) else { return false }
        lastWrite = (id, now())
        return true
    }

    private func isSettling(_ id: CGDirectDisplayID) -> Bool {
        lastWrite.map { $0.display == id && now().timeIntervalSince($0.date) < Self.writeSettleInterval } ?? false
    }

    /// Only a visible strip polls. Extra alone follows display and power notifications.
    private func updatePolling() {
        guard viewers > 0 else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping (ScreenBrightnessController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }
}

extension NSScreen {
    var brightnessDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// macOS has no public backlight API for Apple displays. Resolve DisplayServices
/// optionally; displays it cannot read get a disabled control.
@MainActor
final class NativeScreenBrightnessDevice: ScreenBrightnessDevice {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?

    init() {
        let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        self.library = library
        getBrightness = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: GetBrightness.self) }
        setBrightness = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: SetBrightness.self) }
    }

    func displays() -> [ScreenBrightnessDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.brightnessDisplayID else { return nil }
            return ScreenBrightnessDisplay(
                id: id,
                potentialHeadroom: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
        }
    }

    func read(_ id: CGDirectDisplayID) -> Double? {
        var value: Float = 0
        guard let getBrightness, setBrightness != nil, getBrightness(id, &value) == 0 else { return nil }
        return Double(value)
    }

    func write(_ level: Double, to id: CGDirectDisplayID) -> Bool {
        setBrightness?(id, Float(level)) == 0
    }

    func makeOverlay(for id: CGDirectDisplayID, multiplier: Double,
                     onFailure: @escaping () -> Void) -> BrightnessOverlay? {
        guard let screen = NSScreen.screens.first(where: { $0.brightnessDisplayID == id }) else { return nil }
        return BrightnessBoostOverlay(screen: screen, multiplier: multiplier, onFailure: onFailure)
    }

    deinit { if let library { dlclose(library) } }
}
