---
id: icon-notifications-2026-10-19
type: decision
title: Small notifications cover the island's right wing
summary: Keep large left cards and add temporary branded icons with click-through and a hover close button.
status: confirmed
tags: [notify, notifications, island, accessibility]
canonical_for: [icon-notifications]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: User requested two notification types, automatic disappearance after five seconds, hover enlargement and a small close button; clarified that small icons cover the right wing above hints, meetings and music.
    confirmed_at: 2026-10-19
  - type: commit
    reference: 5512d55b75321be28b34acf3ec52622fb8ba3ee6 (Sources/Sidekey/DynamicIsland/IslandNotificationIcon.swift)
    confirmed_at: 2026-10-19
  - type: user-confirmed
    reference: On 2026-10-19 the user requested a count for consecutive events, overlapping icons that fan apart on hover, Clear All, and a red attention dot only on Notify when returning to the hover drawer.
    confirmed_at: 2026-10-19
  - type: user-confirmed
    reference: On 2026-10-20 the user requested removing the trash icon and Clear All confirmation because the dimmed dialog was difficult to click and the hover closed.
    confirmed_at: 2026-10-20
related: [2026-10-19-script-notifications.md, 2026-10-20-notification-cards-and-sounds.md]
---

# Small notifications

## Context

The user wants small, text-free notifications for events such as an agent
finishing or waiting for an answer, alongside the existing large cards.

## Alternatives

A separate screen-corner icon or a permanent badge were considered. The user
chose the island's right wing and automatic disappearance.

## Decision

Large cards retain their left-side geometry and default lifetime. Small icons
cover the compact right wing in a separate nonactivating panel one window level
above the island, so every current wing state remains underneath and reappears
on expiry/dismissal. No meeting, music or agent state is changed by an overlay.
Both types use the existing bounded queue, history, scoped deduplication,
selected-display routing and screenshot protection.

The optional `presentation` field defaults to `card`; `icon` selects the small
form. Settings exposes this as Notification type: Large / Small. Source defaults
and per-event overrides let agents choose the appropriate form without changing
existing integrations. Old history decodes as cards. Icon events may omit text,
but history and VoiceOver always have a label. Default duration is five seconds,
with the existing bounded duration override retained. Hover pauses expiry and
shake; Reduce Motion disables shake and scale. Closing never opens the link.

Consecutive Small arrivals form a single counted burst, newest first, with up to
three visible layers inside the same wing. Hover fans the icons apart; each keeps
its own action. The close button removes the newest layer. New arrivals restart
the burst timer, including while paused on hover. Expiry dismisses the entire
burst, without deleting history. A queued Large card separates bursts, preserving
FIFO order between presentations. The existing bound of one current plus 32
queued events becomes at most 33 presented/pending events, with excess events
still archived.

The archive retains the newest 500 events. Unseen events leave a red dot only on
Notify in the hover drawer and search, even after temporary expiry or relaunch.
Opening history marks it seen; new events while history is visible are marked
seen as well. Monitor has no attention indicator. Clear All is a text-only action
that immediately clears history, current burst and queue without confirmation,
preserving sources.

## Rationale

The shared queue/archive preserves existing behavior while a higher, temporary
panel covers every wing state without changing the underlying activity.

## Sources

The dated user clarification and implementation path in the frontmatter.

## Comments and objections

The user explicitly corrected the location: inside the right wing, above its
existing contents, rather than beside the island or in a screen corner.

On 2026-10-20 the user reported that the Clear All confirmation dimmed the
screen and the hover closed while trying to click it. They requested removing
both the confirmation and the trash icon. Clear All now acts directly inside
the hover panel.

## Resolution

Expose Large / Small per source and retain per-event overrides for agents.

## Consequences

Codex session links use its documented `codex://threads/<thread-id>` route,
restricted to existing sessions without query parameters. Real completion and
needs-input integrations remain source-specific; branding does not establish
connectivity. Claude Desktop 2.42304.0 has an existing local-session continuation
route `claude://code/continue?session=local_<uuid>` in its installed URL handler.
Only that route is accepted, with no other parameters. Desktop's native session
ID differs from the hook/CLI ID and must be resolved through its session metadata.
Live navigation is a manual acceptance check. Other Claude Code hosts need
their own supported destination; clicks never execute arbitrary commands.

## Supersedes / superseded by

Extends the card-only contract without replacing existing source files or history.

The Small presentation and selector are superseded by
[cards and optional sounds](2026-10-20-notification-cards-and-sounds.md).
