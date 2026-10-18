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
    reference: On 2026-10-18 the user clarified that copied records disappear, confirmed a new record appears in installed 2.2.10 and requested a clipboard history of the latest twenty copies.
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
suppresses Exodia's own dictation write/restore events. The Clipboard feed shows the newest twenty entries in a scrollable list,
following the user's request. The hover retains its five-row viewport; scroll
reveals the remaining copies. Agent and Drop keep their ten-card feeds. These
UI limits do not delete older retained rows. Sleep/wake only stops and starts the watcher.

## Alternatives

Keeping session-only purging reproduces complete loss after every application
restart. The initial ten-card Clipboard feed was expanded to twenty on the
user's follow-up request; additional retention controls are outside this fix. A separate audit observation concerns stale asynchronous tab loads;
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

The earlier 2.2.10 integrated suite passed 2,966 tests, with 8 skipped and
0 failures in 48.542 seconds (`/tmp/exodia-clipboard-retention-full.log`).
The twenty-card follow-up passed 55 focused tests with 0 failures in 0.171
seconds (`/tmp/exodia-clipboard-twenty-focused.log`); its feed test verifies
newest-first ordering, twenty visible records and twenty-five remaining rows
in the isolated store. Independent source review confirmed both hover and
strip consume this default and scroll the full array.

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

The 2.2.10 build1462 candidate was installed and launched normally after the
previous Keychain startup blocker cleared. The user confirmed a new copied
record appears. Before the upgrade, a private local snapshot found zero
clipboard rows; previously erased copies cannot be repopulated from macOS.
The twenty-card follow-up and restart persistence check are pending installation
of the next candidate. No clipboard text or credential contents were inspected.
Public publication remains pending.

## Supersedes

Supersedes the session-only ClipboardHistoryLaunchPurge behavior inherited in
commit 41bfe63b. It does not change Drop, Agent, meeting or project retention.
