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

/// Applies a detached hover surface to the actual panel content so native
/// Liquid Glass on macOS 26+ integrates foreground vibrancy and edge
/// refraction directly on the content view hierarchy, while macOS 14/15
/// retain the layered `IslandDetachedHoverPanelBackground` fallback.
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
                    .glassEffect(
                        .regular,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
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

/// Wraps the hover controls grid in a shared `GlassEffectContainer` on
/// macOS 26+ so circular Liquid Glass tiles share the native rendering context
/// while remaining distinct 44pt circles. Passes content through unchanged
/// on earlier macOS versions.
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
