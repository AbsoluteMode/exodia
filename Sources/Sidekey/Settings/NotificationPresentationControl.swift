import SwiftUI

/// A centered value and an on-demand explanation instead of an overline caption.
struct NotificationPresentationControl: View {
    @Binding var selection: NotifyPresentation
    let sourceName: String
    @State private var showsHelp = false

    var body: some View {
        HStack(spacing: 6) {
            MacPopup(items: [
                .init(value: NotifyPresentation.card, label: "Large"),
                .init(value: NotifyPresentation.icon, label: "Small")
            ], selection: $selection, minWidth: 95)
            .accessibilityLabel("Notification type for \(sourceName)")

            Button { showsHelp.toggle() } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .frame(width: 22, height: MacPopupMetrics.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About notification types")
            .help("Notification type: Large shows a card to the left of the island. Small shows an icon in its right wing.")
            .popover(isPresented: $showsHelp, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notification type").font(.system(size: 13, weight: .semibold))
                    Text("Large shows a card to the left of the island. Small shows an icon in its right wing.")
                        .font(.system(size: 12))
                }
                .padding(16)
                .frame(width: 245, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onExitCommand { showsHelp = false }
            }
        }
    }
}
