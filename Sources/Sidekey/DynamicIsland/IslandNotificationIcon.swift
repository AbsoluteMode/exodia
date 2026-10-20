import SwiftUI

/// A quiet notification: branding only, with a small close control on hover.
// WHY: .project-docs/decisions/2026-10-19-icon-notifications.md
struct IslandNotificationIcon: View {
    let events: [LocalNotificationEvent]
    var height: CGFloat = 38
    var onTap: (LocalNotificationEvent) -> Void
    var onDismiss: (LocalNotificationEvent) -> Void
    var onHoverChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var appeared = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || hovered)) { context in
            IslandNotificationStackContent(events: events, height: height, hovered: hovered,
                rotation: reduceMotion || hovered ? 0 : Self.rotation(elapsed: context.date.timeIntervalSince(appeared)),
                onTap: onTap, onDismiss: onDismiss)
        }
        .contentShape(Rectangle())
        .onHover { value in hovered = value; onHoverChanged(value) }
        .onAppear { appeared = Date() }
        .onChange(of: events.first?.id) { _, _ in appeared = Date() }
    }

    /// Short, gentle bursts with a rest between them. Never runs indefinitely.
    static func rotation(elapsed: TimeInterval) -> Double {
        guard elapsed >= 0, elapsed < 5 else { return 0 }
        let phase = elapsed.truncatingRemainder(dividingBy: 1.2)
        guard phase < 0.65 else { return 0 }
        return sin(phase * .pi * 10) * sin(phase / 0.65 * .pi) * 7
    }
}

@MainActor
struct IslandNotificationIconContent: View {
    let event: LocalNotificationEvent
    var height: CGFloat = 38
    let hovered: Bool
    let rotation: Double
    var onTap: () -> Void
    var onDismiss: () -> Void
    var imageLoader: (String) -> NSImage? = { NotifyLogoStore.image(named: $0) }
    static let width: CGFloat = 70

    var body: some View {
        IslandNotificationStackContent(events: [event], height: height, hovered: hovered,
            rotation: rotation, onTap: { _ in onTap() }, onDismiss: { _ in onDismiss() }, imageLoader: imageLoader)
    }
}

/// Three visible layers keep the fan inside the 70pt wing. The badge counts
/// the entire active burst; removing a layer reveals the next event behind it.
@MainActor
struct IslandNotificationStackContent: View {
    let events: [LocalNotificationEvent]
    var height: CGFloat = 38
    let hovered: Bool
    let rotation: Double
    var onTap: (LocalNotificationEvent) -> Void
    var onDismiss: (LocalNotificationEvent) -> Void
    var imageLoader: (String) -> NSImage? = { NotifyLogoStore.image(named: $0) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visible: [LocalNotificationEvent] { Array(events.prefix(3)) }

    static func centerX(index: Int, count: Int, hovered: Bool) -> CGFloat {
        guard hovered, count > 1 else { return 35 - CGFloat(index) * 6 }
        return count == 2 ? 42 - CGFloat(index) * 23 : 47 - CGFloat(index) * 16
    }

    var body: some View {
        ZStack {
            ForEach(Array(visible.enumerated().reversed()), id: \.element.id) { index, event in
                let size = min(28, height - 6)
                Button { onTap(event) } label: {
                    NotificationSourceIcon(glyph: IslandNotificationPill.resolvedGlyph(for: event,
                        imageExists: { imageLoader($0) != nil }),
                        tint: IslandNotificationPill.resolvedTint(for: event), size: size,
                        imageLoader: imageLoader)
                        .background(RoundedRectangle(cornerRadius: size * 0.3).fill(.black))
                        .overlay(RoundedRectangle(cornerRadius: size * 0.3).stroke(.black, lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .rotationEffect(.degrees(index == 0 ? rotation : (hovered ? 0 : -Double(index) * 5)))
                        .scaleEffect(hovered && !reduceMotion ? 1.05 : (1 - Double(index) * 0.06))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: Self.centerX(index: index, count: visible.count, hovered: hovered),
                          y: height / 2 + (hovered ? 0 : CGFloat(index)))
                .zIndex(Double(visible.count - index))
                .allowsHitTesting(index == 0 || hovered)
                .accessibilityLabel("\(event.sourceName), \(event.title)")
                .accessibilityValue(index == 0 && events.count > 1 ? "\(events.count) notifications" : "")
                .accessibilityHint(event.canActivate ? "Open notification" : "Dismiss notification")
                .accessibilityAction(named: Text("Dismiss notification")) { onDismiss(event) }
            }

            if events.count > 1 {
                Text("\(events.count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).frame(minWidth: 14, minHeight: 13)
                    .background(Capsule().fill(Color(red: 0.95, green: 0.24, blue: 0.22)))
                    .overlay(Capsule().stroke(.black, lineWidth: 1))
                    .position(x: hovered ? 59 : 48, y: 8)
                    .zIndex(4)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }

            if let event = events.first {
                Button { onDismiss(event) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(.black.opacity(0.78)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: 61, y: events.count > 1 ? height - 10 : height / 2)
                .zIndex(5)
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .accessibilityHidden(!hovered)
                .accessibilityLabel("Dismiss newest notification")
            }
        }
        .frame(width: IslandNotificationIconContent.width, height: height)
        // Opaque black matches the island and temporarily covers every hint or
        // activity behind this wing. The panel goes away on dismiss/expiry.
        .background(UnevenRoundedRectangle(bottomTrailingRadius: 12).fill(.black))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: events.map(\.id))
    }
}
