import AppKit
import SwiftUI

@MainActor
struct NotifyHoverPanel: View {
    @ObservedObject var hub: LocalNotificationHub
    @ObservedObject var supervisor: NotifyScriptSupervisor
    let onBack: () -> Void
    let showsBackButton: Bool
    @State private var showsSources = false
    @State private var pendingRemoval: String?
    @State private var confirmsClear = false

    init(hub: LocalNotificationHub? = nil, supervisor: NotifyScriptSupervisor? = nil, showsBackButton: Bool = true, onBack: @escaping () -> Void) {
        self.hub = hub ?? .shared; self.supervisor = supervisor ?? .shared; self.onBack = onBack; self.showsBackButton = showsBackButton
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Group {
                    if showsBackButton { Button(action: onBack) { Label("Tools", systemImage: "chevron.left") }.buttonStyle(.plain) }
                    else { Color.clear.frame(height: 1) }
                }.frame(width: 68, alignment: .leading)
                Text("Notify").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
                Button {
                    if showsSources { NSWorkspace.shared.open(NotifyPaths.root) }
                    else { confirmsClear = true }
                } label: { Image(systemName: showsSources ? "folder" : "trash") }
                .buttonStyle(.plain).frame(width: 68, alignment: .trailing)
                .disabled(!showsSources && hub.history.isEmpty)
                .accessibilityLabel(showsSources ? "Open notification sources folder" : "Clear notification history")
            }
            .font(.system(size: 11, weight: .medium)).frame(height: 24)
            Picker("Notify view", selection: $showsSources) {
                Text("History\(hub.unreadCount > 0 ? " · \(hub.unreadCount)" : "")").tag(false)
                Text("Sources").tag(true)
            }.pickerStyle(.segmented).controlSize(.small)

            if let error = hub.error ?? supervisor.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    if showsSources {
                        if supervisor.sources.isEmpty {
                            empty("No sources yet", detail: "Ask your agent to connect the notifications you want.")
                        }
                        ForEach(supervisor.sources) { source in sourceRow(source) }
                    } else {
                        if hub.history.isEmpty { empty("No notifications yet", detail: "Notifications from your sources appear here.") }
                        ForEach(hub.history) { event in historyRow(event) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .onAppear { Task { await hub.markRead() } }
        .onChange(of: showsSources) { _, value in if !value { Task { await hub.markRead() } } }
        .confirmationDialog("Remove this notification source?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("Remove source", role: .destructive) { if let id = pendingRemoval { supervisor.remove(id: id) }; pendingRemoval = nil }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { Text("Its script will stop. Notification history and script files will be kept.") }
        .confirmationDialog("Clear notification history?", isPresented: $confirmsClear) {
            Button("Clear history", role: .destructive) { Task { await hub.clear() } }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "bell").font(.system(size: 24)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(.vertical, 14).frame(maxWidth: .infinity)
    }
    private func historyRow(_ event: LocalNotificationEvent) -> some View {
        Button {
            if let link = event.link { NSWorkspace.shared.open(link) }
        } label: {
            HStack(spacing: 8) {
                NotificationSourceIcon(glyph: IslandNotificationPill.resolvedGlyph(for: event),
                                       tint: IslandNotificationPill.resolvedTint(for: event), size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(event.body.isEmpty ? event.sourceName : event.body)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(event.timestamp, style: .relative).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: 48)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.055)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(event.link == nil)
        .opacity(1)
        .accessibilityLabel("\(event.sourceName), \(event.title), \(event.body)")
        .contextMenu { Button("Copy text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(event.title + "\n" + event.body, forType: .string) } }
    }
    private func sourceRow(_ source: NotifySourceStatus) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "bell.badge").foregroundStyle(Color(hexCSS: source.script.tint ?? "#299FD6"))
            VStack(alignment: .leading, spacing: 2) {
                Text(source.script.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(source.message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Enabled", isOn: Binding(get: { source.script.enabled }, set: { supervisor.setEnabled($0, id: source.id) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .accessibilityLabel("Enable \(source.script.name)")
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.055)))
        .contextMenu { Button("Remove source…", role: .destructive) { pendingRemoval = source.id } }
    }
}
