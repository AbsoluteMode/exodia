---
id: compact-selection-menus-2026-10-20
type: decision
title: Compact selection menus with one down chevron
summary: Use one compact menu style throughout the app and move the Notifications type caption into a help button.
status: confirmed
tags: [settings, menus, notifications, accessibility, ui]
canonical_for: [selection-menu-appearance]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: 2026-10-20 design chat; Maxim chose Compact menu, requested a question-mark explanation instead of Notification type, vertical centering, and replacement everywhere.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Settings/MacUI/MacPopup.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Settings/NotificationPresentationControl.swift
    confirmed_at: 2026-10-20
related: [../project.md]
---

# Compact selection menus

## Context

The user found the Large/Small selector dated and uneven. The same double-arrow
or accent-arrow appearance was also used by other selection menus.

## Alternatives

- Compact menu: one value and a down chevron, suitable for short or long lists.
- Two segments: both values visible, but wider and unsuitable for longer lists.
- Menu with a preview: explains notification placement, but adds complexity.

## Decision

Use the selected compact-menu design throughout the app: 30 pt height, 8 pt
corners, a neutral fill and border, and one down chevron. `MacMenu` owns the
SwiftUI label and native menu; `MacPopup` adds bound value choices. Model and
OpenRouter provider menus retain their existing content and actions. The
screenshot toolbar uses `MacPopupButton`, an NSPopUpButton with matching cell
geometry, while translation uses the same SwiftUI menu in the system appearance.
Segmented mode controls and action menus keep their existing roles.

Notifications uses `NotificationPresentationControl` for built-in and script
sources. Its menu, question-mark help button and enable switch share the row's
vertical center. The overline caption moves into a tooltip and a clickable
popover describing Large and Small. The menu retains its source-specific
accessibility label and selected value.

## Rationale

One shared label prevents visual drift. Keeping native menu tracking preserves
keyboard navigation, Escape, selection and accessibility. The question-mark
control leaves the row compact while keeping the explanation available by
pointer and keyboard.

## Sources

The user selection and repository components are listed in the frontmatter.

## Comments and objections

No additional objection was recorded after the user selected the compact menu.

## Resolution

Implement the selected menu, with the user's caption and alignment corrections.

## Consequences

Selection bindings, saved values, model probes, provider routing and backup
actions keep their existing paths. Layout and synthetic offscreen rendering are
checked locally; live native menu and popover behavior remains a shared-app
acceptance step until the builder promotes the reviewed candidate.

## Supersedes/superseded by

Replaces the previous accent tile and double-chevron menu presentation. No
earlier canonical menu-style decision was found.
