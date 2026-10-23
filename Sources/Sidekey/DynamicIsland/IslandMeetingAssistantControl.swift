import SwiftUI

/// A session control, separate from the show-only tool/search action.
struct IslandMeetingAssistantControl: View {
    static let height: CGFloat = 44
    let state: MeetingAssistantHoverState
    let setEnabled: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { state.isOn }, set: setEnabled)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Assistant").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                Text(state.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.76))
            }
        }
        .toggleStyle(MeetingAssistantHoverToggleStyle())
        .disabled(!state.canToggle)
        .help("Включить или остановить слушание этой встречи. Следующая встреча не включит его автоматически.")
        .frame(height: Self.height)
    }
}

private struct MeetingAssistantHoverToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Control(configuration: configuration)
    }
    private struct Control: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.islandHoverNativePressed) private var nativePressed
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @FocusState private var focused: Bool
        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 10) {
                    configuration.label
                    Spacer(minLength: 0)
                    Capsule().fill(configuration.isOn ? Color(red: 0.15, green: 0.53, blue: 0.30) : Color.white.opacity(0.22))
                        .frame(width: 30, height: 18)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 0.75))
                        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                            Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                        }
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
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
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(isEnabled ? (configuration.isPressed || nativePressed ? 0.20 : hovered ? 0.10 : 0) : 0)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isEnabled && focused ? .white.opacity(0.85) : .clear, lineWidth: 1.5))
                .onHover { hovered = $0 }
        }
    }
}
