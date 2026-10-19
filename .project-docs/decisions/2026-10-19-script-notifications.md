---
id: script-notifications-2026-10-19
type: decision
title: Restore left-side notifications with app-owned local script sources
summary: Agents configure local scripts whose notifications keep their color and logo in a persistent Notify history.
status: confirmed
tags: [notify, notifications, scripts, agent, history, island]
canonical_for: [script-notifications]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: On 2026-10-19 the user requested notifications configured by their coding agents, scripts active during the app lifetime, history with per-event color and logo, and the previous visual cards left of the island.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Notifications/NotifyScriptSupervisor.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandNotificationPill.swift
    confirmed_at: 2026-10-19
related: [../project.md, 2026-10-19-icon-notifications.md, 2026-10-19-notify-parent-death-guard.md]
---

# Local script notifications

## Context

The user wants a coding agent to ask for the required source/filter/access and
configure notifications, such as selected Telegram events. They explicitly chose
the previous cards left of the island, with history and event-specific branding.

## Alternatives

Restore the removed provider connectors, use system notification banners, or
provide a general local script contract. Provider connectors would constrain
customizations; the user selected the existing left-side presentation.

## Decision

Restore the prior pill design and selected-display geometry in a nonactivating
panel. Add Notify history and source controls. Supervise private local executable
manifests and consume bounded, flushed JSON lines. Stop worker process groups on
quit, sleep, disabling or removal; restart on wake and with bounded error backoff.
No separate service or backend is introduced.

## Rationale

A script can integrate a source using the user's own authorized access without
requiring a new app build. Presentation belongs to the event, so history retains
its color and logo. A local guide and per-turn discovery pointer let both the
built-in agent and external coding agents configure it.

## Sources

The dated user request and implementation paths in the frontmatter.

## Comments and objections

The user corrected the initial presentation question: use the old cards to the
left of the island. No actual Telegram account or chat was selected in this task.

## Resolution

Implement the reusable source mechanism and validate with isolated synthetic
scripts. Do not claim a live Telegram integration or send messages to people.

## Consequences

Scripts run as ordinary local programs, not inside a filesystem sandbox. Agents
must obtain integration-specific access and keep credentials out of manifests,
events and logs. Workers must not detach or daemonize. History retains 500 events;
its bounded deduplication complements each source's private upstream cursor.

## Supersedes / superseded by

Restores notification presentation removed during the open-source pivot without
restoring its retired backend or provider-specific connection system.
