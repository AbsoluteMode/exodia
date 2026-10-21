import SwiftUI

/// Four local bindings, with native menus as the keyboard/VoiceOver alternative
/// to dragging. A drop copies the action and replaces only its destination.
struct ScreenshotArrowSettingsView: View {
    @Binding var bindings: ScreenshotArrowBindings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screenshot arrows")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text)
            Text("Drag an action onto an arrow to replace it, or click an arrow to choose. Save to apply.")
                .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    slot(.up)
                    Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                }
                HStack(spacing: 8) { slot(.left); slot(.down); slot(.right) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(ScreenshotEditorAction.allCases) { action in ScreenshotActionDragSource(action: action) }
            }
            Text("While Screenshot is open, it takes priority over Agent arrows. Text fields keep cursor navigation. Hold Shift with arrows to move the crop, or Option to resize it.")
                .font(.system(size: 11)).foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    private func slot(_ arrow: ScreenshotArrow) -> some View {
        ScreenshotArrowSlot(arrow: arrow, action: bindings[arrow], choose: { bindings[arrow] = $0 }, drop: {
            bindings.replace(arrow, with: $0)
        })
    }
}

private struct ScreenshotArrowSlot: View {
    let arrow: ScreenshotArrow
    let action: ScreenshotEditorAction
    let choose: (ScreenshotEditorAction) -> Void
    let drop: ([String]) -> Bool
    @State private var targeted = false
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Menu {
            ForEach(ScreenshotEditorAction.allCases) { candidate in
                Button { choose(candidate) } label: {
                    if candidate == action { Label(candidate.title, systemImage: "checkmark") }
                    else { Label(candidate.title, systemImage: candidate.symbol) }
                }
            }
        } label: {
            VStack(spacing: 7) {
                HotkeyHintView(contents: [.text(arrow.glyph)])
                Text(action.title)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(MacSettingsTheme.text)
            .frame(maxWidth: .infinity, minHeight: 76)
            .padding(.horizontal, 6)
            .background((targeted ? MacSettingsTheme.accent : MacSettingsTheme.text).opacity(targeted ? 0.16 : hovered ? 0.08 : 0.025),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(targeted || hovered ? MacSettingsTheme.accent : MacSettingsTheme.text2,
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [4, 3]))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(MacButtonInteractionStyle(focused: focused))
        .focused($focused)
        .onHover { hovered = $0 }
        .draggable(action.dragPayload)
        .dropDestination(for: String.self, action: { values, _ in drop(values) }, isTargeted: { targeted = $0 })
        .accessibilityLabel("Screenshot \(arrow.rawValue) arrow")
        .accessibilityValue(action.title)
        .help("\(arrow.glyph): \(action.title). Drag an action here to replace it, drag this assignment to another arrow, or click to choose.")
    }
}

private struct ScreenshotActionDragSource: View {
    let action: ScreenshotEditorAction
    @State private var hovered = false
    var body: some View {
        Label(action.title, systemImage: action.symbol)
            .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(MacSettingsTheme.text.opacity(hovered ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
            .draggable(action.dragPayload)
            .help("Drag \(action.title) onto an arrow. You can also choose it from the arrow's menu.")
    }
}
