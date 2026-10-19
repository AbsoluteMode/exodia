import SwiftUI

/// iOS-style toggle (38×22), accent fill when on. Mirrors the mockup's `.mac-switch`
/// and replaces the old textual ON/OFF switch. Its own colors do not depend on key status.
struct MacSwitch: View {
    /// Regular for Settings rows; compact (30×18) for the island's 24 pt control rows.
    enum Size {
        case regular, compact

        var track: CGSize { self == .regular ? CGSize(width: 38, height: 22) : CGSize(width: 30, height: 18) }
        var knob: CGFloat { track.height - 4 }
    }

    @Binding var isOn: Bool
    var isEnabled: Bool = true
    var size: Size = .regular

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { isOn.toggle() }
        } label: {
            RoundedRectangle(cornerRadius: size.track.height / 2, style: .continuous)
                .fill(isOn ? MacSettingsTheme.accent : Color(hexCSS: "#787880").opacity(0.42))
                .frame(width: size.track.width, height: size.track.height)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: size.knob, height: size.knob)
                        .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
                        .padding(2)
                        .frame(maxWidth: .infinity, alignment: isOn ? .trailing : .leading)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
