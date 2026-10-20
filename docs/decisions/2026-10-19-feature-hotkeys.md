---
id: whytap-feature-hotkeys-2026-10-19
type: decision
title: Bind hover hotkeys to functions rather than positions
summary: Optional named tool shortcuts retain their action when tiles are moved or removed.
status: confirmed
tags: [hotkeys, hover, toolbox, migration]
canonical_for: [tool-hotkey-identity]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: On 2026-10-19 the user rejected numbered hover positions and requested binding a specific feature to a hotkey.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Hotkeys/HotkeyPreferences.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Hotkeys/ToolHotkeyBinding.swift
    confirmed_at: 2026-10-19
related: []
---

# Bind shortcuts to functions

## Context

Five positional shortcuts changed action whenever the user reordered Toolbox.
The growing catalog and variable layout made a position an unreliable identity.

## Alternatives

Keep the positional family; freeze its default tools; or bind stable tool IDs.
Stable IDs express the user's selected function and cover the complete catalog.

## Decision

Settings → Hotkeys lists named tools with optional recordable, clearable
shortcuts. New installs have no optional tool shortcuts. Core bindings retain
their existing defaults. Record has an explicitly labelled additional tool
shortcut beside its primary Meeting record binding.

Persist a dictionary keyed by `HoverTool.rawValue`. Runtime registrations capture
the tool, not a layout index. Hints and Help display only assigned shortcuts.
Actions continue to share the existing router and inline-panel expansion policy.

Migrate explicitly saved legacy slot shortcuts to their current tool once.
Do not synthesize defaults for empty positions or new installs. Preserve legacy
keys, include the dictionary in backups and persist an empty dictionary when
bindings are cleared so old keys cannot repopulate them.

## Rationale

Moving or unpinning a tile should change the drawer, not the keyboard action.
A named binding also makes infrequent, unpinned functions accessible directly.

## Sources

The user request and source paths above establish the requirement and mapping.

## Comments and objections

Existing primary shortcuts such as Meeting record remain available. External
application collisions still use the monitor's existing registration behavior;
this change does not add an operating-system shortcut manager.

## Resolution

Replace the positional runtime and UI with feature bindings. Retain legacy
values solely for migration and backup compatibility.

## Consequences

A shortcut runs a function even when its tile is absent. New catalog cases
appear automatically in the optional Tools section. No provider, permission,
application identity or user-content store changes are involved.

## Supersedes / superseded by

Supersedes the positional shortcut behavior described in earlier hover work.
The tile layout and click/search behavior remain governed by their existing
contracts. No later decision is known.
