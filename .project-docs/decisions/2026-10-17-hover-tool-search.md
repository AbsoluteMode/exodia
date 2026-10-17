---
id: hover-tool-search-2026-10-17
type: decision
title: Search all hover tools without pinning them
summary: Keep frequent tools in the saved grid and find occasional tools through catalog search in the hover drawer.
status: confirmed
tags: [hover, search, keyboard, customization]
canonical_for: [hover-tool-search]
verified_at: 2026-10-17
sources:
  - type: user-confirmed
    reference: User request on 2026-10-17 for hover search to find Output Lang without keeping it among frequent tools.
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverToolSearch.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandView.swift
    confirmed_at: 2026-10-17
related: [../project.md, 2026-10-17-native-hover-glass.md]
---

# Hover catalog search

The controls drawer places a search field above the user's selected tools.
An empty query shows the saved grid. A nonempty query searches the full catalog
by title, description and English/Russian aliases, prioritizing title matches.
Results replace the grid area and can scroll; the drawer keeps its current
height. A query with no matches shows an empty-state message.

Choosing a result invokes the same tool effect as its tile and does not add,
remove or reorder saved tools. In particular, Output Lang remains discoverable
when absent from the saved grid and retains the existing Smart-mode requirement.

Clicking the search field explicitly acquires keyboard focus. Merely hovering
does not take focus from the user's app. Up/Down navigate results, Return opens
the selection and Escape first clears the query, then releases focus. Opening
an inline tool transfers the open state from search focus to the existing
programmatic expansion policy. AppKit receives the full expansion state so
the resulting picker remains clickable while the pointer is outside the pill.
An internal `controlTextDidEndEditing` transition does not resign the key window
between a result's mouse-down and mouse-up. Captured activation or actual window
resignation releases text-entry focus.

Tile and search-result pointer activation uses `IslandHoverHitBridge` with
measured, visible NSView frames. Scrolled-out rows cannot cover the search field
or footer. The same unchanged target must own down and up; leaving it, changing
context or closing the panel cancels the activation. Geometry reporters remain
passive. See [hover material and interaction policy](2026-10-17-native-hover-glass.md).

The controls height includes the 42-point search band for rendering and hit
testing. Settings stays pinned last; the first five saved positions retain
their positional shortcuts. Search is a launcher for occasional tools, not an
alternative persistence format.

## Earlier verification

Before the subsequent user-reported hover regression, on 2026-10-17, the separate Exodia Beta development bundle accepted `output`
and `output lang` in the real hover field. Return and a pointer click each
opened the output-language picker while Output Lang was absent from the saved
grid. Escape closed the picker without changing the selected language. Native
NSSearchField bezel/insets keep the query clear of its search and cancel icons.
The 180 focused hover/search tests passed; full private Control Center optical
equality is outside this functional check.

## Regression follow-up

The later click/focus regression changes measured pointer routing and the
field-editor transition policy described above. The unique v3 native component
fixture verified Settings, Monitor and Case pointer activation with no duplicate
SwiftUI fallback activation while remaining non-key. See the precise checks and
limits in [the hover-glass decision](2026-10-17-native-hover-glass.md). This does
not repeat full search or hover acceptance in the installed production app; the
earlier search check and the component fixture cover different verification scopes.
