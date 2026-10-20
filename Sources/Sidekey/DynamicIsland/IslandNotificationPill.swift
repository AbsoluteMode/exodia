import AppKit
import SwiftUI

enum NotificationCountdown {
    /// Fraction of time REMAINING, in [0, 1]. 1.0 = full time left, 0.0 = expired.
    static func progress(now: Date, deadline: Date, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        let remaining = deadline.timeIntervalSince(now)
        return min(1, max(0, remaining / duration))
    }
    /// Whole seconds remaining, clamped at 0.
    static func remaining(now: Date, deadline: Date) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }
}

/// Notification pill shown in the island's left morph slot. Icon + title + body
/// with a draining tint wash countdown. Dark surfaces only (project theme).
struct IslandNotificationPill: View {
    let event: LocalNotificationEvent
    let deadline: Date
    let duration: TimeInterval
    var onTap: () -> Void = {}
    var onHoverChanged: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Effective Island lifetime: payload override, else the config default.
    static func resolvedDuration(for event: LocalNotificationEvent) -> TimeInterval {
        event.resolvedDuration
    }

    /// Effective accent: payload hex override, else the source's accent.
    static func resolvedTint(for event: LocalNotificationEvent) -> Color {
        if let hex = event.customTint, !hex.isEmpty { return Color(hexCSS: hex) }
        return Color(hexCSS: "#299FD6")
    }

    /// Effective glyph: payload `customLogo` override resolved via LogoStore,
    /// else the source's default asset.
    @MainActor
    static func resolvedGlyph(
        for event: LocalNotificationEvent,
        imageExists: (String) -> Bool
    ) -> LogoGlyph {
        NotifyLogoStore.resolve(logo: event.customLogo, source: event.sourceName, imageExists: imageExists)
    }

    /// Convenience overload for production call-sites (uses real bundle lookup).
    @MainActor
    static func resolvedGlyph(for event: LocalNotificationEvent) -> LogoGlyph {
        NotifyLogoStore.resolve(logo: event.customLogo, source: event.sourceName)
    }

    static let pillHeight: CGFloat = 32
    // WHY: .project-docs/decisions/2026-10-20-notification-cards-and-sounds.md
    private static let cornerRadius: CGFloat = 12

    // Pill content geometry (kept in sync with the `HStack`/padding below).
    private static let iconSize: CGFloat = 22
    private static let contentSpacing: CGFloat = 7
    private static let leadingPadding: CGFloat = 10
    private static let trailingPadding: CGFloat = 12
    /// Gap between the pill and the island, applied by `IslandView` only when
    /// a pill is shown (`.padding(.trailing, 8)` on the reserved left slot).
    private static let slotTrailingGap: CGFloat = 8

    /// Upper bound on the text column's width so the whole pill can never grow
    /// past its reserved slot. Under `.fixedSize(horizontal: true)` the parent
    /// proposes the content's *ideal* width; capping the text column's ideal
    /// with `.frame(maxWidth:)` means short text still hugs (pill shrinks below
    /// the cap) while long text is clamped here so `lineLimit(1)` truncates
    /// with a tail ellipsis instead of overflowing the island.
    ///
    /// Derived so the pill's total width never exceeds the available slot:
    ///   slot(leftNotificationWidth) − slotTrailingGap
    ///     − leadingPadding − iconSize − contentSpacing − trailingPadding
    ///   = 300 − 8 − 10 − 22 − 7 − 12 = 241
    static let textColumnMaxWidth: CGFloat =
        IslandFrameLayout.leftNotificationWidth
        - slotTrailingGap
        - leadingPadding
        - iconSize
        - contentSpacing
        - trailingPadding

    /// Worst-case rendered width of the whole pill: the capped text column
    /// plus every fixed horizontal segment (icon + spacing + paddings). Locked
    /// by an invariant test against the reserved slot so the cap can never be
    /// raised past what the slot can hold.
    static let pillMaxWidth: CGFloat =
        leadingPadding
        + iconSize
        + contentSpacing
        + textColumnMaxWidth
        + trailingPadding

    /// Width actually available to the pill inside its reserved slot
    /// (`leftNotificationWidth` minus the trailing gap `IslandView` adds when a
    /// pill is shown). `pillMaxWidth` must stay ≤ this.
    static let availableSlotWidth: CGFloat =
        IslandFrameLayout.leftNotificationWidth - slotTrailingGap

    /// Hover holds both the visual countdown and the coordinator's real timer.
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { context in
            // Freeze the draining wash while hovered: the displayed
            // progress stops advancing so the bar holds its position
            // under the cursor. `frozenProgress` is captured in `.onHover`
            // at the instant hover begins; the `?? liveProgress` fallback
            // just guards the (unreachable) case where `hovering` is true
            // before a sample was stored.
            let liveProgress = NotificationCountdown.progress(
                now: context.date, deadline: deadline, duration: duration)
            let progress = hovering ? (frozenProgress ?? liveProgress) : liveProgress
            content(progress: progress, hovered: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
            .onHover { isHovering in
                // Capture the wash position at the moment hover begins so
                // it can be held steady; clear on exit so the live drain
                // resumes from wherever the deadline now is.
                if isHovering {
                    frozenProgress = liveProgress
                } else {
                    frozenProgress = nil
                }
                hovering = isHovering
                onHoverChanged(isHovering)
            }
            .onTapGesture { onTap() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(event.sourceName), \(event.title), \(event.body)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
        }
    }

    /// Shared native content lets offscreen checks exercise the actual hover state.
    func content(progress: Double, hovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

        return HStack(spacing: Self.contentSpacing) {
            NotificationSourceIcon(glyph: Self.resolvedGlyph(for: event), tint: Self.resolvedTint(for: event), size: Self.iconSize)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(event.body)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: Self.textColumnMaxWidth, alignment: .leading)
        }
        .padding(.leading, Self.leadingPadding)
        .padding(.trailing, Self.trailingPadding)
        .frame(height: Self.pillHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(wash(progress: progress).clipShape(shape))
        // Dark frame: product is dark-only, but `.popover` material is
        // translucent enough that a light window/wallpaper behind bleeds
        // through and washes the pill out (visible over a light Linear UI).
        // An opaque-ish dark layer over the material keeps the pill readable
        // regardless of what sits behind the island.
        .background(Color.black.opacity(0.8).clipShape(shape))
        .background(IslandVisualEffectBackground().clipShape(shape))
        .overlay(borders(shape: shape))
        .contentShape(shape)
        .brightness(hovered ? 0.06 : 0)
    }

    /// Wash position captured at hover-start, held steady while hovered.
    @State private var frozenProgress: Double?

    /// Draining countdown wash: a full-height tint anchored to the leading
    /// edge whose width = total * progress. As progress falls 1 -> 0 the
    /// trailing edge retreats toward the leading side (drains right -> left).
    @ViewBuilder
    private func wash(progress: Double) -> some View {
        let tint = Self.resolvedTint(for: event)
        GeometryReader { geo in
            LinearGradient(
                stops: [
                    .init(color: tint.opacity(0.35), location: 0.0),
                    .init(color: tint.opacity(0.22), location: 0.62),
                    .init(color: tint.opacity(0.0),  location: 1.0),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: geo.size.width * progress)
        }
    }

    /// Single-line contour: top edge-light + faint sides, no full-perimeter
    /// double border.
    @ViewBuilder
    private func borders(shape: RoundedRectangle) -> some View {
        shape
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.13), .white.opacity(0.05), .clear],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 0.5
            )
    }
}

@MainActor
struct NotificationSourceIcon: View {
    let glyph: LogoGlyph
    var tint: Color
    var size: CGFloat = 22
    var imageLoader: (String) -> NSImage?

    /// For the pill: explicit glyph (supports payload `customLogo` override).
    init(glyph: LogoGlyph, tint: Color, size: CGFloat = 22,
         imageLoader: ((String) -> NSImage?)? = nil) {
        self.glyph = glyph
        self.tint = tint
        self.size = size
        self.imageLoader = imageLoader ?? { NotifyLogoStore.image(named: $0) }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.78)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay(glyphView)
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private var glyphView: some View {
        Group {
            switch glyph {
            case .brandImage(let name):
                if let image = imageLoader(name) {
                    Image(nsImage: image).resizable()
                        .renderingMode(name == "whytap" ? .original : .template).scaledToFit()
                }
            case .symbol(let symbol):
                Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold))
            case .initial(let ch):
                Text(String(ch)).font(.system(size: size * 0.5, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: glyph == .brandImage(name: "whytap") ? size : size * 0.56,
               height: glyph == .brandImage(name: "whytap") ? size : size * 0.56)
    }
}
