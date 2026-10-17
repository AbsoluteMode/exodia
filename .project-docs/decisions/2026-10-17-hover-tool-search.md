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
related: [../project.md]
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

The controls height includes the 42-point search band for rendering and hit
testing. Settings stays pinned last; the first five saved positions retain
their positional shortcuts. Search is a launcher for occasional tools, not an
alternative persistence format.

## Verification

On 2026-10-17, the separate Exodia Beta development bundle accepted `output`
and `output lang` in the real hover field. Return and a pointer click each
opened the output-language picker while Output Lang was absent from the saved
grid. Escape closed the picker without changing the selected language. Native
NSSearchField bezel/insets keep the query clear of its search and cancel icons.
The 180 focused hover/search tests passed; full private Control Center optical
equality is outside this functional check.
