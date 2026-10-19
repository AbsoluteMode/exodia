import SwiftUI

/// The Brightness hover tool: one row with the backlight slider and the Extra
/// switch, and one status line (a notice, or the battery time left).
@MainActor
struct IslandBrightnessStrip: View {
    /// 10 pt padding, a 24 pt control row, 8 pt spacing and a 16 pt status line.
    static let contentHeight: CGFloat = 68
    static let unavailableText = "Brightness isn't adjustable on this display."

    @ObservedObject private var controller: ScreenBrightnessController
    @ObservedObject private var battery: BatteryRuntimeMonitor
    private let onBack: () -> Void

    /// Nil uses the shared instances; default arguments would read them outside the main actor.
    init(controller: ScreenBrightnessController? = nil,
         battery: BatteryRuntimeMonitor? = nil,
         onBack: @escaping () -> Void) {
        self.controller = controller ?? .shared
        self.battery = battery ?? .shared
        self.onBack = onBack
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.75))
                .help("Back to tools")
                .accessibilityLabel("Back to tools")

                BrightnessCapsuleSlider(level: controller.level, isEnabled: controller.isAvailable,
                                        onChange: controller.setLevel)

                if controller.supportsExtra {
                    Toggle(isOn: Binding(get: { controller.isExtraOn }, set: { controller.setExtra($0) })) {
                        Text("Extra")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
                    .help("Adds brightness on top of the current level. Uses more battery.")
                    .accessibilityLabel("Extra brightness")
                }
            }
            .frame(height: BrightnessCapsuleSlider.height)

            if let line = statusLine {
                HStack(spacing: 5) {
                    if let symbol = line.systemImage {
                        Image(systemName: symbol).font(.system(size: 11))
                    }
                    Text(line.text)
                        .font(.system(size: line.isNotice ? 10 : 11))
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(line.isNotice ? AnyShapeStyle(.orange) : AnyShapeStyle(.white.opacity(0.55)))
                .frame(height: 16)
                // Under the slider, not the back button.
                .padding(.leading, 32)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(10)
        // Without a status line the control row stays centered in the strip.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            controller.beginInteraction()
            battery.start()
        }
        .onDisappear {
            controller.endInteraction()
            battery.stop()
        }
    }

    private var statusLine: (text: String, systemImage: String?, isNotice: Bool)? {
        if let notice = controller.notice { return (notice, "exclamationmark.triangle.fill", true) }
        if !controller.isAvailable { return (Self.unavailableText, nil, false) }
        guard let text = BatteryRuntimeFormatter.text(for: battery.status) else { return nil }
        return (text, BatteryRuntimeFormatter.systemImage(for: battery.status), false)
    }
}

/// A Control Center style capsule: white fill from the leading edge with the
/// sun at its start. Clicking or dragging anywhere on it sets the level.
struct BrightnessCapsuleSlider: View {
    static let height: CGFloat = 24
    /// One brightness-key step.
    static let accessibilityStep = 1.0 / 16

    let level: Double
    let isEnabled: Bool
    let onChange: @MainActor (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging = false

    /// The fill always covers the sun at the start, so the pointer maps from
    /// the middle of that start to the middle of the end.
    static func level(atX x: CGFloat, width: CGFloat) -> Double {
        let span = width - height
        guard span > 0 else { return 0 }
        return ScreenBrightnessScale.clampedLevel(Double((x - height / 2) / span))
    }

    static func fillWidth(level: Double, width: CGFloat) -> CGFloat {
        height + max(0, width - height) * CGFloat(ScreenBrightnessScale.clampedLevel(level))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule()
                    .fill(.white.opacity(isEnabled ? 0.95 : 0.4))
                    .frame(width: Self.fillWidth(level: level, width: width))
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.55))
                    .frame(width: Self.height, height: Self.height)
            }
            // The fill follows the pointer directly while dragging.
            .animation(dragging || reduceMotion ? nil : .easeOut(duration: 0.15), value: level)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        onChange(Self.level(atX: value.location.x, width: width))
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: Self.height)
        .opacity(isEnabled ? 1 : 0.6)
        .allowsHitTesting(isEnabled)
        .accessibilityElement()
        .accessibilityLabel("Brightness")
        .accessibilityValue("\(Int((ScreenBrightnessScale.clampedLevel(level) * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(level + Self.accessibilityStep)
            case .decrement: onChange(level - Self.accessibilityStep)
            @unknown default: break
            }
        }
    }
}
