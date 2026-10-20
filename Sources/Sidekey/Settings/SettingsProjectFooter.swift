import AppKit
import SwiftUI

/// App identity and browser destinations share a type scale, but separate rows.
struct SettingsProjectFooter: View {
    let identity: AppBuildIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(identity.name) \(identity.version)")
                .foregroundStyle(MacSettingsTheme.text2)
                .padding(.horizontal, SettingsSidebarStyle.buttonHorizontalPadding)

            Rectangle()
                .fill(MacSettingsTheme.sep)
                .frame(height: 1)
                .padding(.horizontal, SettingsSidebarStyle.buttonHorizontalPadding)
                .accessibilityHidden(true)

            HStack(spacing: 4) {
                SettingsFooterLink(title: "whytap.ai", destination: URL(string: "https://whytap.ai")!)
                SettingsFooterLink(title: "GitHub", destination: BuildConfig.landingURL, brand: "github")
            }
            .padding(.horizontal, SettingsSidebarStyle.buttonHorizontalPadding - 6)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }
}

private struct SettingsFooterLink: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let destination: URL
    var brand: String?

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 5) {
                icon
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
            }
        }
        .buttonStyle(SettingsFooterLinkStyle())
        .help(destination.absoluteString)
        .accessibilityLabel(title)
        .accessibilityHint("Opens \(destination.absoluteString) in your browser")
    }

    @ViewBuilder
    private var icon: some View {
        if let brand, let image = UsefulLinkIconAsset.image(named: brand) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
        } else {
            Circle()
                .strokeBorder(colorScheme == .dark ? Color.white : Color.black, lineWidth: 1.5)
        }
    }
}

private struct SettingsFooterLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovered || configuration.isPressed ? MacSettingsTheme.text : MacSettingsTheme.text2)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(configuration.isPressed ? MacSettingsTheme.selection : (hovered ? MacSettingsTheme.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .background(SettingsFooterLinkCursor())
                .onHover { hovered = $0 }
        }
    }
}

/// Cursor rectangles follow view/window lifetime without a global cursor stack.
private struct SettingsFooterLinkCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }

    func updateNSView(_ nsView: CursorView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
