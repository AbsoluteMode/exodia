---
id: clipboard-retention-2026-10-18
type: decision
title: Keep local clipboard history across application restarts
summary: Remove automatic launch and quit purges while retaining the fifty-entry cap and image-sidecar eviction.
status: confirmed
tags: [clipboard, history, persistence, macos]
canonical_for: [clipboard-history-retention]
verified_at: 2026-10-18
sources:
  - type: user-confirmed
    reference: On 2026-10-18 the user reported that Clipboard in History keeps disappearing; whether this referred to the tab or its entries was asked separately.
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/AppDelegate.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/History/SQLiteHistoryStore.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/History/ClipboardHistoryStoreTests.swift
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-clipboard-retention-focused.log, 55 tests with 0 failures in 0.114 seconds.
    confirmed_at: 2026-10-18
related: [../project.md]
---

# Clipboard retention

## Context

The inherited implementation erased every clipboard row and every image
sidecar both at application launch and during normal termination. Its comment
described session-only retention as a privacy contract. Consequently, application
updates and ordinary restarts emptied Clipboard even though the SQLite store
already supported persistence. The user's reported disappearance prompted the
audit; code establishes this deletion mechanism, not that every reported visual
disappearance has the same cause.

## Decision and rationale

Clipboard belongs to the local workspace. Launch opens the existing database
and starts the watcher without clearing it; termination stops the watcher
without deleting saved copies. Remove the obsolete launch-purge helper and
the now-unused full-wipe store method. No migration or new storage location is
needed. The existing fifty-entry cap remains: inserting the fifty-first copy
evicts the oldest entry and its image file if applicable.

The watcher still ignores the current pasteboard payload at startup and
suppresses Exodia's own dictation write/restore events. The History feed still
shows the newest ten entries; this UI limit does not delete older retained
rows. Sleep/wake only stops and starts the watcher.

## Alternatives

Keeping session-only purging reproduces complete loss after every application
restart. Adding retention controls or changing the visible feed limit is outside
this fix. A separate audit observation concerns stale asynchronous tab loads;
that affects display rather than stored data and is not changed here.

## Sources and verification

The source diff removes both lifecycle deletion calls. Focused tests cover
text persistence, repeated reopening of file/image payloads and image bytes,
synchronous watcher stop/start, and fifty-entry eviction after reopening.
They use temporary stores and synthetic payloads. The watcher lifecycle test
does not yield its main actor, so its timer cannot poll the user's clipboard.
These tests do not execute full AppDelegate launch/quit, decode fixture image
bytes, or establish installed-application acceptance.

An independent source review found no other full clipboard deletion path;
the remaining production deletion enforces the existing cap.

The full integrated suite passed 2,966 tests, with 8 skipped and 0 failures
in 48.542 seconds (`/tmp/exodia-clipboard-retention-full.log`).

## Comments and objections

The old session-only rule limited retention of any sensitive copies. The new
rule deliberately retains the existing bounded local history between sessions;
this is documented in the privacy guide. No clipboard data is uploaded.

## Resolution and consequences

Records already erased by older versions cannot be recovered by this patch.
An old running binary still has its termination purge. Before replacing it,
preserve its local clipboard database and assets privately, then restore only
clipboard rows/assets after that process has quit. Do not overwrite newer
agent or dictation history with an entire older database snapshot.

Installed acceptance and public publication remain pending. The currently
installed candidate is also blocked on a macOS Keychain authorization request;
no credential contents were inspected.

## Supersedes

Supersedes the session-only ClipboardHistoryLaunchPurge behavior inherited in
commit 41bfe63b. It does not change Drop, Agent, meeting or project retention.
