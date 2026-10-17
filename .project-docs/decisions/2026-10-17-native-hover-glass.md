---
id: native-hover-glass-2026-10-17
type: decision
title: Native Apple Liquid Glass for hover surfaces
summary: Match hover to the actual compact island width with three smaller capsules per row, real inline status and one independent Regular backdrop.
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
  - type: user-confirmed
    reference: User selected three horizontal capsules per row with icon, title and current status inside on 2026-10-17, and requested Monitor dashboards inside hover.
    confirmed_at: 2026-10-17
  - type: user-confirmed
    reference: User clarified on 2026-10-17 that hover must have the same width as the island and confirmed three smaller capsules per row; this supersedes the earlier wider drawer.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-matched-width-focused-tests.log, 69 focused tests with 0 failures for the compact-width candidate.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-matched-width-full-tests.log, full 2947 tests with 8 skipped and 0 failures in 45.315 seconds for the compact-width candidate.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-compact-hover-offscreen/render-manifest.json and source-manifest.json, 18 actual-component offscreen renders at 310/312 points with source-hash match and no visible/key windows.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-capsules-final-tests.log, final 2947 tests with 8 skipped and 0 failures after the inline legacy callback and functional-test migration.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-capsule-offscreen-proof/render-manifest.json and source-manifest.json, 21 actual-component offscreen renders with no visible or key windows.
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverPanelControl.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/HoverToolPresentation.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/Monitor/MonitorHoverPanel.swift
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
with the white controls. The 2.2.2 refinement addressed those surfaces;
its actual-field v4 check is separate from the earlier v3 fixture. The 2.2.3
candidate added three-column capsules and inline Monitor. After seeing that
layout, the user clarified on 2026-10-17 that hover should match the island's
width and confirmed three smaller capsules per row. That correction governs the
current development candidate, planned as 2.2.4; it is not yet release proof.

## Decision

On macOS 26 and later, apply one SwiftUI `glassEffect(.regular, in:)` backdrop per
drawer or music-strip card, on an independent transparent rounded rectangle
inside `content.background`. Do not apply the material modifier to the whole
foreground hierarchy: the lens gradient, rim and icon keep their independent
colors, matching the user's separate-layer reference. The current controls are
compact horizontal capsules in `IslandHoverPanelControl.swift`, defaulting to
90x52 points with a 24-point left icon disk, blue standard glyph, normal-case
11-point title and optional 10-point status inside. Each grid instance receives
the width calculated from the actual compact island width. They are foreground
gradient/rim lenses without
a child native glass effect. `HoverToolPresentation` derives actual mode,
language and recording status; stateless navigation tools have no status. Apple's [WWDC25 session 323](https://developer.apple.com/videos/play/wwdc2025/323/)
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

`HoverLayoutStore.columns` remains three. `IslandHoverControlsLayout` calculates
capsule width as `(panelWidth - 24 - 16) / 3`: three 90-point capsules fit a
310-point island, while a 312-point island gives each capsule about 90.67 points.
It centers 52-point targets in 68-point rows with a 76-point row stride,
eight-point row/column spacing and 12-point horizontal insets. New-install
defaults have six tools, two rows and a 243-point host band; existing selections
persist. Only four rows are visible, in a 312-point grid viewport. Thirteen
tools retain 388 points of full scroll content without removing anything from
the saved layout. Settings remains last and the first five positional hotkeys
are independent of the column count. Hints overlay stable targets.

The drawer, search, detached inline panels, music and native hit zones all use
the actual notch-derived `compactWidth`, rather than a fixed wider drawer.
History preview uses `leftHostReservation(compactWidth:)` with the original
300-point reservation and zero drawer overhang. A 280-point preview plus an
eight-point gap still leaves twelve points of padding, without shifting the
compact island's right/top anchors. Reserved capacity is not an extra
mouse-active area.

Monitor launches inline from capsules, search and positional hotkeys through
`.openPanel(.monitor)`. `MonitorHoverPanel.contentHeight` is 344 points, with a
dashboard picker, Server status/custom content, Refresh and Back navigation.
The inline route enables `compactPresentation`: server metrics stack vertically
and custom widgets use one flexible column, fitting the compact drawer while
the legacy window retains its existing layout. It starts/stops the existing
MonitorStore with view visibility, without opening
a separate window or duplicating collectors. The standalone window remains for
compatibility as a class only. The production legacy `openMonitor` callback
also publishes an inline Monitor request with programmatic expansion; see
[dashboard contracts](../../docs/customization/dashboards.md).

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

The user's later equal-width correction supersedes the 2.2.3 457-point drawer
and 139x64-point capsule geometry. It retains three columns, icon/title/status,
inline Monitor and existing persistence; it does not request one long row or a
wider compact island.

The older layered material remains the fallback for runtimes before macOS 26
and older toolchains. Availability guards preserve the macOS 14.2 deployment
floor. This decision does not restore the June fixed opaque wash to the native
path or flatten live glass into an offscreen bitmap.

## Current compact candidate verification

The planned 2.2.4 candidate passed 69 focused tests with 0 failures and the full
2,947-test suite with 8 skipped and 0 failures in 45.315 seconds. The matching
source produced 18 actual capsule/search-layout offscreen renders at both
310-point and 312-point widths; the render/source manifests record matching
source hashes, no visible windows and no key windows. Standard and long-language
text-audit outputs were inspected. The dark audit backing is test-only.

These are geometry/text checks with synthetic states and an empty native-field
layout; they do not render the production search-result switch. They do not
prove the native compositor, real pointer activation, physical keyboard
input/focus or live Monitor-button interaction. Production acceptance and release
publication remain separate. None of the earlier fixtures or 2.2.3 results
establishes acceptance for this smaller layout. Do not display GUI test windows
over the user's work.

## Historical 2.2.3 candidate verification

The final suite passed 2,947 tests with 8 skipped and 0 failures in 42.184 seconds,
after the legacy callback was made inline and obsolete source-pattern checks
were replaced with functional routing, effect, spy and AX-state contracts.

The offscreen proof contains 21 PNGs plus render/source manifests for the actual
139x64 capsules and three-column 457-point grid. Its manifest records no visible
or key windows. Six-tool and thirteen-tool text audits covered long-status
ellipsis and layout fit without overflow. The deliberate black test backing is
not a rendered native-glass result. Native compositor output, real pointer
activation, keyboard focus and live Monitor-button interaction were not proved
by these offscreen checks; production acceptance remains separate.

That earlier wider drawer used `leftHostReservation(compactWidth:)` with a
300-point reservation plus 73.5 points of overhang for a 310-point island. Those
values describe the superseded 2.2.3 geometry, not the current compact candidate.

The earlier fixture results below predate this capsule/inline-Monitor change.
No new test windows may appear over the user's work.

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
