import SwiftUI

/// The hover hosts the same dashboard/server content and polling store as the
/// standalone Monitor. No window activation or collector implementation here.
@MainActor
struct MonitorHoverPanel: View {
    nonisolated static let contentHeight: CGFloat = 344
    @StateObject private var store: MonitorStore
    @State private var selectedID: String?
    let onBack: () -> Void

    init(store: MonitorStore? = nil, onBack: @escaping () -> Void) {
        self._store = StateObject(wrappedValue: store ?? MonitorStore())
        self.onBack = onBack
    }

    private var selectedDashboard: MonitorDashboard? {
        store.dashboards.first { $0.id == selectedID }
    }

    private var title: String {
        if selectedID == "server-status" { return "Server status" }
        return selectedDashboard?.title ?? "Monitor"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    if selectedID == nil { onBack() }
                    else { selectedID = nil }
                } label: {
                    Label(selectedID == nil ? "Tools" : "Dashboards", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if selectedID != nil {
                    Button { store.requestRefresh() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh dashboard")
                }
            }
            .frame(height: 26)

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)

            if let error = store.dashboardError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Group {
                if selectedID == nil {
                    dashboardPicker
                } else if selectedID == "server-status" {
                    MonitorServersView(store: store, allowsOpeningFolder: false, showsHeader: false,
                                       compactPresentation: true)
                } else if let dashboard = selectedDashboard {
                    MonitorCustomDashboardView(dashboard: dashboard, showsTitle: false,
                                               compactPresentation: true)
                } else {
                    Text("This dashboard is no longer available. Choose another dashboard.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { store.start() }
        .onDisappear { store.stop() }
    }

    private var dashboardPicker: some View {
        ScrollView {
            VStack(spacing: 8) {
                dashboardButton(id: "server-status", title: "Server status",
                                image: "server.rack", subtitle: "CPU, memory and GPU readings")
                ForEach(store.dashboards) { dashboard in
                    dashboardButton(id: dashboard.id, title: dashboard.title,
                                    image: dashboard.systemImage, subtitle: dashboard.subtitle)
                }
                Text("Your agent can add custom dashboards to this Mac's Monitor folder.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                if store.dashboards.isEmpty {
                    Text(store.dashboardsDirectory.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func dashboardButton(id: String, title: String, image: String, subtitle: String) -> some View {
        Button { selectedID = id } label: {
            HStack(spacing: 8) {
                Image(systemName: image)
                    .font(.system(size: 18))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14), lineWidth: 0.7))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
