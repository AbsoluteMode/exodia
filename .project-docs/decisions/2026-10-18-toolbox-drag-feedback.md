---
id: toolbox-drag-feedback-2026-10-18
type: decision
title: Toolbox drop targets match insertion positions and show immediate feedback
summary: The permanent Add target precedes pinned Settings, highlights while targeted and uses a short layout animation when a completed drop changes the saved tools.
status: confirmed
tags: [toolbox, hover, drag-and-drop, animation, accessibility]
canonical_for: [toolbox-drag-feedback]
verified_at: 2026-10-18
sources:
  - type: user-confirmed
    reference: On 2026-10-18 the user reported delayed placeholder filling and apparent freezing while dragging tools into the hover registry in Settings, then approved trying the two reviewed fixes.
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/Settings/ToolboxSettingsView.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/Settings/ToolboxHoverEditorTests.swift
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-toolbox-drag-focused-tests.log, 28 focused tests with 0 failures in 2.289 seconds.
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-toolbox-drag-proof/manifest.json, 14 actual editor/card/Add PNGs and source hash, unordered non-key windows with isolated preferences.
    confirmed_at: 2026-10-18
related: [../project.md]
---

# Toolbox drag feedback

## Context

The editor previously drew Add after Settings but inserted new tools before
Settings. With six saved tools, releasing a new tool over Add placed it in
the preceding row; Settings moved into the released cell and Add moved again.
The targets had no drag-entry feedback and the grid did not animate changes.

An isolated production-store probe returned from mutation plus UserDefaults
set in a median 0.058 ms (2,000 mutations). This excludes UI subscribers,
native dragging, payload loading, frame rendering and durable disk flush; it
does not establish the cause or duration of a physical UI pause.

## Decision

`ToolboxHoverEditor` owns the grid separately from the tool configuration
panels. Its stable item identities are the tool IDs and one permanent Add ID.
It draws editable tools, Add, then pinned Settings. A new tool therefore fills
the previous Add position, including when insertion crosses a row boundary.
Settings remains last in the saved layout and the editor and has no drop
target. Valid self/end drops with no order change are accepted without a
preference write, avoiding failed-drop return feedback.

`isTargeted` updates only transient highlighting. The accent overlay does not
change layout, intercept events or add accessibility elements. Late exit events
clear only their own target. Highlighting uses 0.1 seconds and committed grid
changes use 0.18-second easing with an opacity insertion/removal transition.
Reduce Motion disables both animations.

Only the completed drop action calls `HoverLayoutStore.placeTool`. Its target
index is resolved from the current tool identity rather than a captured grid
index. Drag entry and cancellation do not persist layout changes. The store,
raw IDs, positional hotkeys and plain-view draggable source remain unchanged.

## Alternatives

Reordering saved preferences on every drag-entry event was rejected: an
aborted drag would then need rollback and moving targets could cause jitter.
Animating or changing the live island was outside this Settings-only fix.

## Verification boundary

Hosted checks use an isolated defaults suite and the actual editor in an
unordered offscreen window, without initializing Case/Vocab/provider stores.
All 28 focused tests passed. Fourteen before/after PNGs were captured and the
five-tool pair was inspected. They check Add-to-tool coordinates across row boundaries, removal, reordering
and Reduce Motion transactions. No GUI test window may appear over the user's
work. Native pointer dragging and perceived smoothness require installed-app
acceptance; hidden layout checks do not prove an NSDragging latency fix.
