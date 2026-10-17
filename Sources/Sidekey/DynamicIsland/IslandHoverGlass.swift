import SwiftUI

enum IslandHoverGlass {
    /// Whether the current runtime supports native macOS 26 Liquid Glass.
    static var usesNativeLiquidGlass: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }
}

/// Applies a native macOS 26+ optical backdrop separately from foreground
/// lenses and icons, preserving their colors. Earlier systems retain the
/// layered `IslandDetachedHoverPanelBackground` fallback.
struct IslandHoverGlassSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = IslandDropModeControl.detachedPanelCornerRadius
    var showGlass: Bool = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if !showGlass {
            content
                .background(Color.clear)
                .clipShape(shape)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content
                    .background {
                        // Keep the optical backdrop separate from the foreground
                        // lenses, matching the reference's independent layers.
                        shape.fill(Color.clear)
                            // Regular retains adaptive contrast over bright
                            // desktops when this panel becomes key for search.
                            .glassEffect(.regular, in: shape)
                            // Active appearance only; the utility stays non-key.
                            .environment(\.appearsActive, true)
                    }
                    .overlay {
                        IslandHoverGlassRim(shape: shape)
                            .allowsHitTesting(false)
                    }
            } else {
                legacySurface(content: content, shape: shape)
            }
            #else
            legacySurface(content: content, shape: shape)
            #endif
        }
    }

    private func legacySurface(content: Content, shape: RoundedRectangle) -> some View {
        content
            .background(IslandDetachedHoverPanelBackground(cornerRadius: cornerRadius))
            .clipShape(shape)
    }
}

/// Thin specular edge and inner lens, inspired by the user's LiquidButton
/// reference. Keep the native backdrop visible and every decorative layer
/// outside mouse routing.
struct IslandHoverGlassRim<S: InsettableShape>: View {
    let shape: S
    var highlighted = false

    var body: some View {
        shape
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(highlighted ? 0.95 : 0.75), location: 0),
                        .init(color: .white.opacity(0.12), location: 0.35),
                        .init(color: .white.opacity(0.08), location: 0.65),
                        .init(color: .white.opacity(highlighted ? 0.70 : 0.45), location: 1)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
            .overlay {
                shape.inset(by: 1)
                    .strokeBorder(.white.opacity(highlighted ? 0.22 : 0.12), lineWidth: 2)
                    .blur(radius: 1.2)
                    .clipShape(shape)
            }
    }
}

/// Preserves the shared controls container on macOS 26+. Circular foreground
/// lenses remain distinct 44pt controls without nested native glass effects.
/// Passes content through unchanged on earlier macOS versions.
struct IslandHoverGlassControlsContainer<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

extension View {
    /// A foreground input lens shares its card's backdrop rather than adding
    /// nested native glass. Its interior stays transparent while editing.
    @ViewBuilder
    func islandHoverInputLens(cornerRadius: CGFloat) -> some View {
        if IslandHoverGlass.usesNativeLiquidGlass {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            self
                .background {
                    shape.fill(LinearGradient(
                        colors: [.white.opacity(0.14), .white.opacity(0.055)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .allowsHitTesting(false)
                }
                .overlay {
                    IslandHoverGlassRim(shape: shape).allowsHitTesting(false)
                }
        } else {
            self
        }
    }

    func islandHoverGlassSurface(
        cornerRadius: CGFloat = IslandDropModeControl.detachedPanelCornerRadius,
        showGlass: Bool = true
    ) -> some View {
        modifier(
            IslandHoverGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                showGlass: showGlass
            )
        )
    }
}
