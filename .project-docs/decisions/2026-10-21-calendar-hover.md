---
id: whytap-calendar-hover
type: decision
title: Calendar stays inside Hover and opens on today
summary: Show a compact daily agenda, inline details and Connect; reuse provider authorization with Settings Integrations.
status: confirmed
tags: [calendar, hover, integrations, planner, oauth]
canonical_for: [calendar-presentation]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user requested that Calendar stay inside Hover, open on the current day and offer Connect; different calendars can be added there or through Integrations.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarHoverView.swift
    confirmed_at: 2026-10-21
related: [2026-10-21-calendar-integrations.md, 2026-10-20-todo-hover.md]
---

# Calendar in Hover

This supersedes the standalone Planner window as Calendar's normal entry.
The Calendar tile, tool search, assigned hotkey and `whytap://tool/calendar`
all open the same inline panel. Every new opening selects today, including
a repeated Calendar hotkey. Day navigation stays local to that opening.

The header keeps **Connect** visible. The agenda, full event details, source
visibility and provider selection share the same 350pt Hover surface. No
calendar/detail/connection window is created from these paths. Provider
authorization can open a browser or macOS permission prompt; it is an optional
calendar connection, never registration or sign-in to Whytap.

Connect reuses CalendarConnectView, its PKCE/state validation, public-approval
gates, Keychain storage and serialized connection lease. Settings → Integrations
offers the same providers. Feed visibility and local tasks/events keep their
existing storage and backup formats. Advanced app setup remains collapsed in
Hover for source users' own registrations; Settings cards do not expose it.

Polling fetches the selected day only, on opening/day/account/refresh changes
and once per minute while visible. Native calendar-change notifications refresh
EventKit feeds. A day boundary follows today unless the user navigated away.
Events remain read-only in Hover; retained local events are displayed alongside
connected sources, including events spanning midnight and all-day events.

The menu survives pointer exit. Outside click/Escape dismisses it, except during
the provider permission flow so switching to the browser cannot cancel OAuth.
Explicit Cancel/Back can cancel a connection. The menu reacquires keyboard focus
when the connection finishes. All buttons/rows have full-area hover, press,
focus and disabled states; the fixed hit band includes the whole panel.

A visible Calendar defers restore/update restart. Ordinary read-only backup is
unaffected. Google verification and Zoom publication remain pending; this UI
change neither grants permissions nor marks either provider approved.

The legacy Planner editor types and archive are retained for compatibility;
this change does not delete or migrate tasks, events, accounts or credentials.
