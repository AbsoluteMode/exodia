import SwiftUI

/// A session control, separate from the show-only tool/search action.
struct IslandMeetingAssistantControl: View {
    static let height: CGFloat = 44
    let state: MeetingAssistantHoverState
    let setEnabled: (Bool) -> Void
    var hitBridge: IslandHoverHitBridge? = nil
    var hitContext = ""

    var body: some View {
        Group {
            if let hitBridge, state.canToggle {
                control.islandHoverHitTarget(bridge: hitBridge, id: .init(surface: .meetingAssistant, tool: .meetingAssistant),
                                             context: hitContext, action: { setEnabled(!state.isOn) })
                    .islandHoverHitRegion(bridge: hitBridge, surface: .meetingAssistant)
            } else { control }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
    }
    private var control: some View {
        Toggle(isOn: Binding(get: { state.isOn }, set: setEnabled)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Assistant").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                Text(state.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.76))
            }
        }
        .toggleStyle(MeetingAssistantHoverToggleStyle(status: state.subtitle))
        .disabled(!state.canToggle)
        .help("Включить или остановить слушание этой встречи. Следующая встреча не включит его автоматически.")
        .frame(height: Self.height)
    }
}

private struct MeetingAssistantHoverToggleStyle: ToggleStyle {
    let status: String
    func makeBody(configuration: Configuration) -> some View {
        Control(configuration: configuration, status: status)
    }
    private struct Control: View {
        let configuration: ToggleStyleConfiguration
        let status: String
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.islandHoverNativePressed) private var nativePressed
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @FocusState private var focused: Bool
        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 10) {
                    configuration.label
                    Spacer(minLength: 0)
                    Capsule().fill(configuration.isOn ? MacSettingsTheme.accentFill : MacSettingsTheme.switchOff)
                        .frame(width: MacSwitch.Size.compact.track.width, height: MacSwitch.Size.compact.track.height)
                        .overlay(Capsule().strokeBorder(MacSettingsTheme.switchBorder, lineWidth: 0.75))
                        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                            Circle().fill(.white).frame(width: MacSwitch.Size.compact.thumb.width, height: MacSwitch.Size.compact.thumb.height)
                                .padding(MacSwitch.Size.compact.inset)
                        }
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: IslandMeetingAssistantControl.height)
            }
            .buttonStyle(Feedback(focused: focused, nativePressed: nativePressed))
            .focused($focused)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: configuration.isOn)
            .onMoveCommand { direction in
                guard isEnabled else { return }
                if direction == .left { configuration.isOn = false }
                if direction == .right { configuration.isOn = true }
            }
            .accessibilityRepresentation {
                Toggle("Meeting Assistant — только эта встреча", isOn: configuration.$isOn)
                    .toggleStyle(.switch).disabled(!isEnabled)
                    .accessibilityValue(Text("\(configuration.isOn ? "Включён" : "Выключен"). \(status)"))
            }
        }
    }
    private struct Feedback: ButtonStyle {
        var focused: Bool
        var nativePressed: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .background(MeetingAssistantHoverSurface(hovered: hovered, pressed: configuration.isPressed || nativePressed,
                                                        focused: focused, enabled: isEnabled))
                .onHover { hovered = $0 }
        }
    }
}

/// Shared by live interaction and offscreen feedback proofs.
struct MeetingAssistantHoverSurface: View {
    var hovered = false
    var pressed = false
    var focused = false
    var enabled = true
    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.white.opacity(enabled ? (pressed ? 0.20 : hovered ? 0.10 : 0) : 0))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(enabled && focused ? .white.opacity(0.85) : .clear, lineWidth: 1.5))
            .allowsHitTesting(false)
    }
}
