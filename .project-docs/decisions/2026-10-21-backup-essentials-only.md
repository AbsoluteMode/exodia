---
id: whytap-backup-essentials-only
type: decision
title: Back up meeting text but no meeting audio or History database
summary: Backups no longer carry retained meeting recordings or the History database (clipboard, recent dictations, agent answers); the history section holds Costs, restoring a newer archive leaves both stores on the Mac untouched, and older archives still restore them.
status: confirmed
tags: [backup, meetings, history, clipboard, disk, github]
canonical_for: [backup-content-scope]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user decided that backups keep only what matters — meeting text, not audio (meeting text only, no recordings), and no clipboard history, which can be taken from the Mac at any time; meeting audio is only useful for debugging in development builds.
    confirmed_at: 2026-10-21
  - type: trace
    reference: Metadata sizes on the maintainer's Mac (du, no content read) — meetings-staging 2.4 GB, history.sqlite 147 MB plus 33 MB WAL/images, versus 95 MB for meeting text, Notify, Case, Costs, planner and agent memory together.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Backup/ArtifactBackupStaging.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Backup/ArtifactBackupRestore.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/Backup/ArtifactBackupRestoreTests.swift
    confirmed_at: 2026-10-21
related: [2026-10-21-backup-capture-pacing.md, 2026-10-19-config-backup.md, 2026-10-21-backup-reliability.md, 2026-10-20-simple-github-backup.md, 2026-10-21-backup-tagged-caches.md]
---

# Back up meeting text but no meeting audio or History database

## Context

Every backup is a complete encrypted archive. In the observed profile it was
about 2.6 GB: 2.4 GB of retained meeting audio (`meetings-staging`, recordings
kept after failed processing and their originals) and 180 MB of the History
database with its WAL and clipboard images. Everything else — meeting catalog,
notes and transcripts, Notify and Monitor, Case, Costs, planner, agent memory,
settings and keys — was about 95 MB. Clipboard copies also changed the backup
on every copy. The user decided that a backup keeps only the important data:
meeting text, not audio, and no clipboard history.

## Decision

- The meetings section carries the catalog, notes and transcripts only.
  `meetings-staging` is never read by a backup, whatever it contains (parked
  records, nested originals, provider job files, links, stray files).
- The History database (`history.sqlite`, its WAL and `history-assets`:
  clipboard entries and images, recent dictations and agent answers) is not
  exported. The history section now carries only Costs, and is absent from an
  archive when no Costs journal exists. Section titles are "Meeting notes" and
  "Costs".
- The change probe no longer watches these paths, so their churn never marks a
  backup pending.
- Restore replaces the staging directory or the History database only when the
  archive actually carries them. A newer archive therefore leaves this Mac's
  recordings and History untouched; archives made before this change still
  restore them, recordings with their finalize record parked as before.
- The app keeps retaining recordings for its own retry/repair paths; whether it
  should keep audio at all is a separate decision.

## Why

- Audio was 90% of every archive and of every complete upload to GitHub,
  while it is debugging material in production. Text notes and transcripts are
  the durable result of a meeting.
- Clipboard content can be copied again on the Mac; recent dictations and agent
  answers are short-lived feeds. Excluding the whole database is simpler than
  filtering rows and merging the target's clipboard back on restore.
- File metadata suggests a complete archive around 95 MB (about 27 times
  smaller). Each capture and upload is smaller; the fixed 10 GB automatic and
  2 GB manual reserves and hourly pacing stay unchanged. The actual archive
  size still needs verification after a user starts a backup.

## Tested

- A full backup of a profile with retained audio, clipboard text, a file link
  and an image produces no `meetings/staged/` or `history/` entries and no
  related warnings; restoring it into a clean profile creates no staging
  directory or History database.
- Damaged excluded data (a missing clipboard image, a missing recording chunk,
  a stray file in the staging root, a link inside a recording) no longer fails
  a backup.
- Clipboard copies and new recording chunks do not change the content
  fingerprint or the change probe; an agent-memory edit still does.
- Restoring a newer archive with meetings, Costs and workspace keeps the
  target's History database, WAL, images and recordings. With the restore
  narrowing reverted, the same test fails on all four.
- Older archives: a 3 MB retained recording streams through many frames and
  restores byte for byte with its record parked; a legacy History database
  replaces stale WAL files; an archive without Costs leaves Costs untouched.

## Rejected

- Keeping Drop and agent rows while dropping clipboard rows: restore would
  replace the target's clipboard with an empty table unless rows were merged.
- Keeping only the newest recordings: still gigabytes per archive.
- Refusing old archives that carry audio: they are the user's existing copies
  and must stay restorable.

## Supersession

This replaces "retained unfinished recordings" and "Agent, Drop and clipboard
history, including app-managed image bytes" in the configuration backup
decision, the retained-recording coverage of the reliability decision (schema 4
still reads it), the recording entry ceiling of the simple GitHub backup
decision and the retained-recordings clause of the tagged-cache decision.
Encryption, verification, schema and recovery-code contracts are unchanged.

2026-10-21 · PR AbsoluteMode/whytap#199
