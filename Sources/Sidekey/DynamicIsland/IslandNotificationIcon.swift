import SwiftUI

/// A quiet notification: branding only, with a small close control on hover.
// WHY: .project-docs/decisions/2026-10-19-icon-notifications.md
struct IslandNotificationIcon: View {
    let event: LocalNotificationEvent
    var height: CGFloat = 38
    var onTap: () -> Void
    var onDismiss: () -> Void
    var onHoverChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var appeared = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || hovered)) { context in
            IslandNotificationIconContent(event: event, height: height, hovered: hovered,
                rotation: reduceMotion || hovered ? 0 : Self.rotation(elapsed: context.date.timeIntervalSince(appeared)),
                onTap: onTap, onDismiss: onDismiss)
        }
        .contentShape(Rectangle())
        .onHover { value in hovered = value; onHoverChanged(value) }
        .onAppear { appeared = Date() }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 70

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onTap) {
                NotificationSourceIcon(glyph: IslandNotificationPill.resolvedGlyph(for: event,
                    imageExists: { imageLoader($0) != nil }),
                    tint: IslandNotificationPill.resolvedTint(for: event), size: min(28, height - 6),
                    imageLoader: imageLoader)
                    .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                    .rotationEffect(.degrees(rotation))
                    .scaleEffect(hovered && !reduceMotion ? 1.10 : 1)
                    .frame(width: Self.width, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(event.sourceName), \(event.title)")
            .accessibilityHint(event.link == nil ? "Dismiss notification" : "Open notification")
            .accessibilityAction(named: Text("Dismiss notification"), onDismiss)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(.black.opacity(0.78)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    .frame(width: 20, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
            .accessibilityHidden(!hovered)
            .accessibilityLabel("Dismiss notification")
        }
        .frame(width: Self.width, height: height)
        // Opaque black matches the island and temporarily covers every hint or
        // activity behind this wing. The panel goes away on dismiss/expiry.
        .background(UnevenRoundedRectangle(bottomTrailingRadius: 12).fill(.black))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
    }
}
