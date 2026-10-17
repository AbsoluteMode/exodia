---
id: native-hover-glass-2026-10-17
type: decision
title: Native Apple Liquid Glass for hover surfaces
summary: Use adaptive native glass for the hover drawer and controls on macOS 26, retaining the earlier material on older systems.
status: confirmed
tags: [macos, hover, liquid-glass, swiftui, accessibility]
canonical_for: [hover-glass-material]
verified_at: 2026-10-17
sources:
  - type: user-confirmed
    reference: User request on 2026-10-17 to delegate Apple Liquid Glass hover styling to the Argon agent, with a Control Center reference image.
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverGlass.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandView.swift
    confirmed_at: 2026-10-17
  - type: url
    reference: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
    confirmed_at: 2026-10-17
related: [../project.md]
---

# Native hover glass

## Decision

On macOS 26 and later, apply SwiftUI `glassEffect(.regular, in:)` to the actual
hover drawer content and the separate music-strip content. Circular controls use
`regular.interactive()` at their existing 44-point footprint, within a shared
`GlassEffectContainer`. Do not cover the native material with the earlier dark
wash, specular ellipse or hand-painted rims. Foreground labels and tool actions
remain part of the existing hover view.

The native path uses system pointer/press responses. The earlier magnetic
translation and manual pressed scaling remain only on the legacy path. Tool
ordering, row counts, panel heights, positional shortcuts and the history
panel's transparent presentation retain their existing behavior.

Builds with an older Swift toolchain, or runtimes before macOS 26, retain the
layered material. Native APIs have compiler and runtime availability guards;
the application deployment floor stays at macOS 14.2.

## Rationale and supersession

The June decision in `docs/decisions/2026-06-16-island-music-progress-and-gap.md`
preferred a fixed wash to keep differently positioned surfaces the same color,
and described an older build SDK without native glass symbols. The current
SDK supports these symbols, and the user's explicit choice is the native Apple
appearance. Backdrop-dependent color differences between separate surfaces are
therefore accepted. The existing separate cards and eight-point gaps stay.

The target is Apple's public native material, not a claimed pixel-identical
reimplementation of private Control Center rendering. Native optical effects
require the window compositor; an offscreen bitmap of a hosting view alone does
not verify their appearance. Use live native previews for visual inspection and
focused geometry/action tests for functional regressions.

## Sources

The dated user request, current source files and official Apple API guide in the
frontmatter establish this decision. The Argon worker authored the native
surface/container adapter; the calling agent integrated it and owns validation.
