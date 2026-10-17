---
id: native-hover-glass-2026-10-17
type: decision
title: Native Apple Liquid Glass for hover surfaces
summary: Use an independent Regular backdrop for bright-background contrast, transparent search and History lenses, and explicit hover feedback without changing pointer geometry.
status: confirmed
tags: [macos, hover, liquid-glass, swiftui, accessibility]
canonical_for: [hover-glass-material]
verified_at: 2026-10-17
sources:
  - type: user-confirmed
    reference: User request on 2026-10-17 to delegate Apple Liquid Glass hover styling to the Argon agent, with a Control Center reference image.
    confirmed_at: 2026-10-17
  - type: user-confirmed
    reference: User feedback on 2026-10-17 reported flat gray glass, off-center buttons, missing hover feedback and unreliable clicks; the supplied LiquidButton reference requested a transparent lens with a bright edge and inner shine.
    confirmed_at: 2026-10-17
  - type: user-confirmed
    reference: User feedback after the 2.2.1 publication on 2026-10-17 reported black search and History surfaces and insufficient white-foreground contrast when focused Clear glass was shown over a white background.
    confirmed_at: 2026-10-17
  - type: user-confirmed
    reference: User requested on 2026-10-17 that test windows never appear over their work again; subsequent visual checks must remain offscreen.
    confirmed_at: 2026-10-17
  - type: trace
    reference: build/visual-reference/exodia-search-v4-query-white.png and exodia-search-v4-pattern.png, local CUA-inspected actual-field fixture screenshots on 2026-10-17; bitmaps are not committed.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-hover-panels-focused-tests.log, 109 focused tests with 0 failures for the Regular/search/History candidate.
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverToolSearch.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/History/HistoryHoverView.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/History/HistoryHoverPreview.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverGlass.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandView.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverHitBridge.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandDropModeControl.swift
    confirmed_at: 2026-10-17
  - type: trace
    reference: build/visual-reference/exodia-hover-lenses-v3.png, local native fixture screenshot inspected on 2026-10-17; the bitmap is not committed.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-hover-fix-full-tests.log, 2928 tests with 8 skipped and 0 failures before the final presentation-only background modifier.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-hover-v3-focused-tests.log, 94 focused tests with 0 failures after the final background modifier.
    confirmed_at: 2026-10-17
  - type: url
    reference: https://developer.apple.com/videos/play/wwdc2025/323/
    confirmed_at: 2026-10-17
  - type: url
    reference: https://developer.apple.com/documentation/swiftui/environmentvalues/appearsactive
    confirmed_at: 2026-10-17
  - type: url
    reference: https://github.com/i-am-logger/macos-liquid-glass/blob/ccf01c88648400562c55a1366151f6f0c8b6f663/examples/common/mod.rs#L654-L671
    confirmed_at: 2026-10-17
  - type: url
    reference: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
    confirmed_at: 2026-10-17
related: [../project.md, 2026-10-17-hover-tool-search.md]
---

# Native hover glass

## Context

The first native-glass change used Regular material and delegated pointer
feedback to the native interactive effect. The user subsequently reported flat
gray glass, buttons displaced from the center, lost hover feedback and unreliable
clicks. Their LiquidButton reference requested a transparent lens with a bright
edge and inner shine. These reports supersede the earlier visual and interaction
policy; they are not a claim that every macOS backdrop renders identically.

The released 2.2.1 then received production feedback: search and History still
looked black, while focused Clear glass over a white background lost contrast
with the white controls. The current 2.2.2 candidate addresses those surfaces;
its actual-field v4 check is separate from the earlier v3 fixture.

## Decision

On macOS 26 and later, apply one SwiftUI `glassEffect(.regular, in:)` backdrop per
drawer or music-strip card, on an independent transparent rounded rectangle
inside `content.background`. Do not apply the material modifier to the whole
foreground hierarchy: the lens gradient, rim and icon keep their independent
colors, matching the user's separate-layer reference. The 44-point circular
controls are foreground
lenses made from a translucent gradient fill, `IslandHoverGlassRim` and the icon;
they do not apply a child native glass effect. Apple's [WWDC25 session 323](https://developer.apple.com/videos/play/wwdc2025/323/)
explains that glass does not sample other glass. Avoid layering independent
native backdrops on top of the parent card. The existing controls container
remains, with explicit centered layout. Set `appearsActive=true` on the optical
background's environment without making the utility panel key. Apple's [appearsActive documentation](https://developer.apple.com/documentation/swiftui/environmentvalues/appearsactive)
controls preferred active styling; acquiring keyboard focus is a separate action.

Regular replaces Clear for adaptive contrast over white backgrounds, including
when search makes the panel key. Keep the independent backdrop and foreground
rims/lenses; do not restore an opaque black surface or nested native glass.
On macOS 26+, a custom `NSSearchFieldCell` draws its interior without the black
bezel, preserving native geometry and button tracking. Its shared field editor
is transparent; a foreground gradient/rim supplies the input lens. History uses
the common drawer backdrop, translucent row/hint lenses and an independent
preview backdrop. Existing macOS 14/15 fallback and transparent Case/Vocab/Filler
panels are retained.

Add `IslandHoverGlassRim` as a thin specular edge and inner highlight, preserving
the native backdrop. The overlay uses `allowsHitTesting(false)` and never routes
a click. This is an original native implementation guided by the user's visual
reference; no third-party source was copied or dependency added. The
[pinned MIT upstream example](https://github.com/i-am-logger/macos-liquid-glass/blob/ccf01c88648400562c55a1366151f6f0c8b6f663/examples/common/mod.rs#L654-L671)
selects Clear rather than Regular and describes its own observed opacity
contrast. It is a reference, not proof of Exodia's visual result.

Restore explicit magnetic movement and hover/pressed scale feedback on both the
native and legacy paths. Reduce Motion suppresses translation, scaling and their
spring animations. The native material does not replace the control's explicit
feedback contract.

`IslandHoverControlsLayout` centers the complete fixed-height button in each
row. Shortcut hints overlay its top edge and do not consume layout height.
Shared geometry keeps one and two rows at 187 and 283 points respectively;
ordering, row counts, positional hotkeys and separate eight-point panel gaps
retain their existing behavior.

Pointer dispatch belongs to `IslandHoverHitBridge` at `NSWindow.sendEvent`, using
measured target NSView frames clipped to visible scroll and region bounds. An
activation requires mouse-down and mouse-up on the same unchanged control.
Leaving a captured target cancels activation even if the pointer returns.
Context/geometry changes and Escape also cancel it while retaining ownership of
the eventual mouse-up. Hiding the panel discards the pending sequence without
activation. Geometry reporters never intercept clicks themselves.
Search focus is released by captured activation or actual window resignation,
not by an internal field-editor transition between down and up.

## Alternatives and supersession

The current Regular background supersedes Clear after the production white-
background contrast report. This is distinct from the first whole-content
Regular treatment: the background remains separate from foreground lenses.
The earlier same-day policy used `regular.interactive()` and restricted manual
motion and painted rims to older macOS. An intermediate Clear variant still put
native glass on both parent cards and child circles; the current refinement
replaces those child effects with foreground lenses. These earlier approaches
are superseded by the user's regression feedback and transparent-lens reference.
The prior requirement to apply native glass to the actual foreground content
for integrated vibrancy is also superseded: the optical backdrop is independent
of the foreground lenses and their colors. Merely increasing blur or making the
window key would not address the requested feedback and non-activating behavior.

The older layered material remains the fallback for runtimes before macOS 26
and older toolchains. Availability guards preserve the macOS 14.2 deployment
floor. This decision does not restore the June fixed opaque wash to the native
path or flatten live glass into an offscreen bitmap.

## Verification scope

The earlier Clear v3 native fixture was visually inspected through CUA on
2026-10-17, before the subsequent 2.2.1 production feedback.
White foreground edges and translucent lenses were visible, and the one-row and
two-row layouts were centered. A Settings click set the one-row Native counter
to 1; Monitor and Case clicks set the cumulative two-row Native counter to 1
and then 2. Each click activated once, SwiftUI fallback stayed 0, and the utility
remained non-key (`liveKey=false`). The local
screenshot is `build/visual-reference/exodia-hover-lenses-v3.png`; the bitmap is
not committed.

This verifies the component fixture over its controlled checkerboard backdrop.
It does not establish installed production-app behavior, sampling of the user's
external desktop, complete hover/accessibility acceptance or optical equality to
Control Center. Those checks must be reported separately; fixture results do not
establish a public release or successful production installation.

The Regular/search/History v4 fixture was checked through CUA on white and
patterned backdrops. Clicking the actual search field set `liveKey=true` and
`searchFocused=true`. AX `setValue` to `output` updated the delegate-bound query
and showed the native cancel button. First Escape cleared the query while the
window stayed key; second Escape released focus and key status. The card,
buttons and History row remained visible over both backgrounds. The 109 focused
tests passed with 0 failures.

These checks establish controlled editor appearance and delegate binding.
Automated typeText/paste did not verify physical keypress input and caused focus
loss, so no physical-typing claim is made. Installed production hover acceptance
and the external-desktop compositor remain separate checks. The local screenshots
are `exodia-search-v4-query-white.png` and `exodia-search-v4-pattern.png` under
`build/visual-reference/`; bitmaps are not committed.

The fixture was closed after inspection. At the user's explicit request,
subsequent checks must stay offscreen and must not show test windows over their
work. Offscreen results do not establish external-desktop optical behavior.

For the earlier Clear candidate, the full suite passed 2,928 tests with 8 skipped
and 0 failures before the final
presentation-only move of Clear glass onto its independent background shape.
Focused tests cover target identity, drag cancellation, viewport clipping, row
geometry and search field-editor transitions. The final focused run passed 94
tests with 0 failures after that last modifier; the earlier full run is not
presented as a rerun after it.

## Sources

The dated user requests and feedback, current native source files, Apple's
public API documentation and the pinned MIT example establish the decision.
The upstream reference explains the material choice; Exodia's own implementation
and live inspection determine its behavior.
