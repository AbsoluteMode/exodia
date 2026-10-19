import AppKit
import Combine
import CoreGraphics

/// One brightness key event. The Mac's brightness keys arrive as system-defined events
/// with the aux control button subtype; data1 packs the key type, the key state and the
/// repeat bit.
struct BrightnessKeyEvent: Equatable {
    enum Direction: Hashable { case up, down }
    /// The Mac's own steps: a sixteenth, or a quarter of that with Option-Shift.
    enum Step: Equatable { case normal, fine }

    let direction: Direction
    let isDown: Bool
    let isRepeat: Bool
    /// Nil for a combination macOS keeps, such as Option to open Displays settings.
    let step: Step?

    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS.
    static let auxControlSubtype: Int16 = 8
    /// NX_KEYTYPE_BRIGHTNESS_UP and NX_KEYTYPE_BRIGHTNESS_DOWN.
    private static let upKey = 2, downKey = 3
    /// NX_KEYDOWN and NX_KEYUP in the key state byte.
    private static let downState = 0x0A, upState = 0x0B

    static func parse(subtype: Int16, data1: Int, flags: CGEventFlags) -> BrightnessKeyEvent? {
        guard subtype == auxControlSubtype else { return nil }
        let direction: Direction
        switch (data1 & 0xFFFF_0000) >> 16 {
        case upKey: direction = .up
        case downKey: direction = .down
        default: return nil
        }
        let state = (data1 & 0xFF00) >> 8
        guard state == downState || state == upState else { return nil }
        return BrightnessKeyEvent(direction: direction, isDown: state == downState,
                                  isRepeat: data1 & 0x1 != 0, step: step(for: flags))
    }

    /// Fn (the function-key row) and Caps Lock do not change the key.
    static func step(for flags: CGEventFlags) -> Step? {
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if modifiers.isEmpty { return .normal }
        return modifiers == [.maskAlternate, .maskShift] ? .fine : nil
    }
}

/// The keys move between sixteenths of the backlight range (64ths with Option-Shift).
/// From between two marks a press goes to the next mark at least a quarter step away,
/// so a level read back slightly off a mark still moves a whole step.
enum BrightnessKeyStep {
    static func level(after level: Double, direction: BrightnessKeyEvent.Direction,
                      step: BrightnessKeyEvent.Step) -> Double {
        let divisions: Double = step == .fine ? 64 : 16
        let position = ScreenBrightnessScale.clampedLevel(level) * divisions
        let mark = direction == .up ? floor(position + 0.25) + 1 : ceil(position - 0.25) - 1
        return ScreenBrightnessScale.clampedLevel(mark / divisions)
    }
}

/// Two brightness-up presses at the maximum within 1.5 s ask for Extra. The press that
/// reaches the maximum is not one of them; repeats from holding the key neither count nor
/// cancel, and any other press starts over.
struct BrightnessExtraKeyGesture {
    static let window: TimeInterval = 1.5
    private var firstPressAtTop: Date?

    mutating func register(_ direction: BrightnessKeyEvent.Direction, isRepeat: Bool, levelBefore: Double,
                           at date: Date) -> Bool {
        guard !isRepeat else { return false }
        guard direction == .up, levelBefore >= ScreenBrightnessScale.hardwareMaximum else {
            firstPressAtTop = nil
            return false
        }
        if let first = firstPressAtTop, date.timeIntervalSince(first) <= Self.window {
            firstPressAtTop = nil
            return true
        }
        firstPressAtTop = date
        return false
    }
}

/// Decides on the tap thread which events Exodia keeps from macOS. A press belongs wholly
/// to Exodia or to macOS: its repeats and its release follow its first event, so macOS
/// never sees half a press. A combination macOS keeps is never taken.
struct BrightnessKeyFilter {
    private var kept: [BrightnessKeyEvent.Direction: Bool] = [:]

    mutating func shouldSwallow(_ event: BrightnessKeyEvent, intercepting: Bool) -> Bool {
        guard event.isDown else { return kept.removeValue(forKey: event.direction) ?? false }
        if event.isRepeat, let owner = kept[event.direction] { return owner }
        let mine = intercepting && event.step != nil
        kept[event.direction] = mine
        return mine
    }
}

/// Applies a kept press: one step of the island display's backlight, or Extra on the
/// second brightness-up press at the maximum. Either way the strip shows.
@MainActor
final class BrightnessKeyHandler {
    private let controller: ScreenBrightnessController
    private let showStrip: @MainActor () -> Void
    private let now: () -> Date
    private var gesture = BrightnessExtraKeyGesture()

    init(controller: ScreenBrightnessController, showStrip: @escaping @MainActor () -> Void,
         now: @escaping () -> Date = Date.init) {
        self.controller = controller
        self.showStrip = showStrip
        self.now = now
    }

    func handle(_ event: BrightnessKeyEvent) {
        guard event.isDown, let step = event.step else { return }
        // A closed strip does not follow the backlight, so read it. Right after a write the
        // controller keeps the written level, so presses in a row add up.
        controller.refresh()
        let before = controller.level
        let asksForExtra = gesture.register(event.direction, isRepeat: event.isRepeat, levelBefore: before,
                                            at: now())
        if asksForExtra, controller.supportsExtra, !controller.isExtraOn {
            controller.setExtra(true)
        } else {
            let next = BrightnessKeyStep.level(after: before, direction: event.direction, step: step)
            if next != before { controller.setLevel(next) }
        }
        showStrip()
    }
}

/// The event tap behind Brightness keys, so tests can run without one.
@MainActor
protocol BrightnessKeyTapping: AnyObject {
    /// Installs the tap. False when macOS refuses it (no Accessibility permission).
    /// `deliver` receives each kept key-down; `onFailure` reports that macOS stopped the tap.
    func start(deliver: @escaping @MainActor (BrightnessKeyEvent) -> Void,
               onFailure: @escaping @MainActor () -> Void) -> Bool
    func stop()
    /// Whether new presses go to Exodia instead of macOS.
    func setIntercepting(_ intercepting: Bool)
}

/// Settings -> Toolbox -> Display -> Brightness keys, off by default. While it is on, the
/// Mac's brightness keys change the island display in Exodia instead of macOS: the strip
/// shows instead of the system indicator, and two brightness-up presses at the maximum turn
/// Extra on. The keys stay with macOS while hover is hidden, while the island display is not
/// adjustable, and with Command, Control, Option or Shift alone. Nothing about the keys is
/// logged or stored.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
final class BrightnessKeys: ObservableObject {
    static let shared = BrightnessKeys()
    static let defaultsKey = "sidekey.preferences.brightnessKeys"

    @Published private(set) var isEnabled: Bool
    /// The tap is installed. Off while enabled means macOS refused it.
    @Published private(set) var isListening = false

    private let defaults: UserDefaults
    private let controller: ScreenBrightnessController
    private let tap: BrightnessKeyTapping
    private let now: () -> Date
    private var handler: BrightnessKeyHandler?
    private var displayAvailable = false
    private var hoverWidgetsHidden = false
    private var subscriptions: Set<AnyCancellable> = []

    /// Nil uses the shared instances; default arguments would read them outside the main actor.
    init(defaults: UserDefaults = .standard,
         controller: ScreenBrightnessController? = nil,
         tap: BrightnessKeyTapping? = nil,
         hoverHidden: AnyPublisher<Bool, Never>? = nil,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        let controller = controller ?? .shared
        self.controller = controller
        self.tap = tap ?? BrightnessKeyEventTap()
        self.now = now
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
        // @Published delivers the new value before the property changes, so keep the delivered one.
        controller.$isAvailable
            .sink { [weak self] available in
                self?.displayAvailable = available
                self?.updateInterception()
            }
            .store(in: &subscriptions)
        (hoverHidden ?? DisplayPreferences.shared.$hideIslandHoverWidgets.eraseToAnyPublisher())
            .sink { [weak self] hidden in
                self?.hoverWidgetsHidden = hidden
                self?.updateInterception()
            }
            .store(in: &subscriptions)
    }

    /// Launch and the permission repair call this. With the setting on, it installs the tap
    /// unless it is already listening. The first handler stays: Drop's repair calls this every
    /// second while Drop is not installed, and a new handler would forget a press at the top.
    func start(showStrip: @escaping @MainActor () -> Void) {
        if handler == nil {
            handler = BrightnessKeyHandler(controller: controller, showStrip: showStrip, now: now)
        }
        guard isEnabled, !isListening else { return }
        listen()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        if enabled { listen() } else { stopListening() }
    }

    /// Settings shows the switch: a tap macOS refused earlier may be allowed now.
    func retryIfNeeded() {
        guard isEnabled, !isListening else { return }
        listen()
    }

    /// Quit. The setting stays for the next launch.
    func stop() {
        stopListening()
    }

    private func listen() {
        // Without a handler a kept press would do nothing, so the keys stay with macOS.
        guard handler != nil else { return }
        controller.refresh()
        isListening = tap.start(deliver: { [weak self] event in self?.handler?.handle(event) },
                                onFailure: { [weak self] in self?.stopListening() })
        updateInterception()
    }

    private func stopListening() {
        tap.stop()
        if isListening { isListening = false }
        updateInterception()
    }

    private func updateInterception() {
        tap.setIntercepting(isEnabled && isListening && displayAvailable && !hoverWidgetsHidden)
    }
}
