---
id: history-free-page-scrub-2026-10-22
type: decision
title: Scrub the History database's free pages once and zero future deletes
summary: The History connection runs with secure_delete=ON, and each history.sqlite file is rewritten once with VACUUM off the main thread, keeping every row; the version lives in the file, and low disk space or an incomplete checkpoint retries on the next launch.
status: confirmed
tags: [clipboard, history, privacy, sqlite, macos]
canonical_for: [history-free-page-scrub]
verified_at: 2026-10-22
sources:
  - type: user-confirmed
    reference: On 2026-10-22 the user chose both a one-time VACUUM and secure_delete for the History connection, after an explanation of what each does.
    confirmed_at: 2026-10-22
  - type: trace
    reference: The maintainer's history.sqlite had 36,752 pages of 4 KB (150 MB), 24,987 of them on the freelist (about 102 MB), so about 48 MB of live pages; read with read-only PRAGMA page_count/freelist_count and dbstat sizes, never row content. The system libsqlite3 3.54.0 defaults to secure_delete=FAST (2).
    confirmed_at: 2026-10-22
  - type: trace
    reference: VACUUM of a synthetic database of the same shape (36,263 pages, 24,500 free, 800 KB values) took 142-253 ms on the maintainer's Mac and left a 48 MB file with no free pages.
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/History/SQLiteHistoryStore.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Tests/SidekeyTests/History/HistoryFreePageScrubTests.swift
    confirmed_at: 2026-10-22
related: [2026-10-22-clipboard-entry-delete.md, 2026-10-18-clipboard-retention.md, 2026-10-21-clipboard-privacy-markers.md, 2026-10-21-backup-essentials-only.md, ../../docs/decisions/2026-06-24-island-history-off-main.md]
---

# Scrub the History database's free pages

## Context

On 2026-10-21 an App Store Connect private key copied through the clipboard
was recorded in clipboard history.
[Privacy markers](2026-10-21-clipboard-privacy-markers.md) stop marked copies,
and [Delete…](2026-10-22-clipboard-entry-delete.md) erases one row with
`secure_delete` and truncates the WAL. Neither touches what earlier deletes
left behind. The 50-entry clipboard cap, the Drop cap and agent-chat trimming
deleted rows on a connection with the system default `secure_delete=FAST`.
FAST zeroes deleted cells only in pages it rewrites anyway; overflow pages of
long values go to the freelist with their bytes intact. B-tree rebalancing
can also leave copies of cells in the spare space of live pages. On the
maintainer's Mac about 102 MB of the 150 MB file were free pages; some may
hold the key or other old copies. Row content was not read to check.

## Decision

- `SQLiteHistoryStore.init` sets `PRAGMA secure_delete = ON` for its
  connection. Every later delete (cap eviction, `enforceDropCap`,
  `deleteAgentEntries`, `wipeAllAgentEntries`, Delete…) zeroes the removed
  bytes and the pages it frees. Delete…'s temporary per-statement switch is
  removed as redundant; its truncating checkpoint stays.
- `scrubFreePagesIfNeeded()` runs `VACUUM`, then
  `sqlite3_wal_checkpoint_v2(..., TRUNCATE)`, then records version 1 under
  `free_page_scrub` in a new `history_maintenance` table. A recorded version
  skips the pass. The version is recorded only after the checkpoint returned
  `SQLITE_OK`: an incomplete checkpoint, a VACUUM error or too little disk
  space records nothing and the next launch tries again.
- The space check needs `2 × live pages + 64 MB` free on the database's
  volume (`volumeAvailableCapacityForImportantUsage`). VACUUM writes a
  temporary copy of the live pages and the same pages again through the WAL;
  the file's free pages need no room.
- `AppDelegate` calls `scrubFreePagesInBackground` once the History stores are
  set up. It runs on a utility queue and logs only the outcome and freed byte
  count (or SQLite's error text).

## Rationale

- **Both steps.** VACUUM alone would let the next evictions leave new
  fragments; `secure_delete` alone leaves what is already there. The user
  chose both.
- **VACUUM keeps History.** It rebuilds the same rows into fresh pages. All
  tables have `INTEGER PRIMARY KEY AUTOINCREMENT`, so ids and
  `sqlite_sequence` survive. The UI, Delete… and the ⌥V strip keep working
  with ids they already hold. This is not a lifecycle wipe
  ([clipboard retention](2026-10-18-clipboard-retention.md)).
- **Cost.** A one-time rewrite of the live pages (about 0.2 s and 48 MB
  written for the measured shape). With `secure_delete=ON`, a cap eviction of
  a long copy also writes zeros over its freed pages: a few hundred KB per
  copy at most, at human copy rate.
- **Off the main thread, on the store queue.** Launch never waits. The pass
  holds the store's serial queue, so a copy recorded at that moment waits up
  to its duration instead of failing with `SQLITE_BUSY`, which a second
  connection would cause. History card reads were already off the main thread
  ([island history off main](../../docs/decisions/2026-06-24-island-history-off-main.md)).
- **Version in the file, not UserDefaults.** A beta build shares the
  production History file with its own defaults domain, and restoring a
  pre-2026-10-21 archive brings back an older file. A record inside the file
  matches that file's actual state; a defaults flag would mark a restored,
  unscrubbed file as done.
- **Checkpoint before recording.** After VACUUM in WAL mode the new pages are
  first in the `-wal`; the main file shrinks and loses its old pages only when
  a checkpoint completes. Recording after a successful truncating checkpoint
  leaves no window where the record exists but the old pages remain.

## Verification

`Tests/SidekeyTests/History/HistoryFreePageScrubTests.swift`, temporary files
with synthetic markers only:

- a database built like an older version (rows deleted with
  `secure_delete=OFF`: a short cell, long clipboard/Drop/agent values) loses
  every marker from the database and WAL files after the scrub, while its kept
  rows remain;
- text, image, file-list, Drop and agent rows (with title/blocks/status) are
  unchanged, the image sidecar stays, and an id after a deleted newest row is
  not reused;
- the second pass and a new connection report `alreadyScrubbed`; a copy of
  the file made before the scrub is scrubbed again;
- too little space returns `skippedLowDiskSpace` for the database's directory
  with the markers still present, and the next pass scrubs;
- long clipboard, Drop and agent values removed by the caps/trimming on a new
  connection are not readable in the file after it closes (the mutation
  without `PRAGMA secure_delete = ON` fails this test);
- the background pass runs off the main thread, and 20 copies recorded while
  it runs are all kept.

The existing Delete… on-disk test still passes without the per-statement
switch. These checks do not run the installed app or measure the real
database; acceptance in the working app is separate.

## Alternatives rejected

- Only one of the two steps: see Rationale.
- Running VACUUM synchronously in `init`: launch would wait on the main
  thread.
- A second connection for VACUUM: History writes would hit `SQLITE_BUSY`
  (no busy timeout) and lose copies.
- `VACUUM INTO` a new file and swapping it in: the open connection still
  points at the old inode; more failure modes for no privacy gain.
- `PRAGMA auto_vacuum=INCREMENTAL`: changing it needs a full VACUUM anyway and
  does not zero pages.
- A versioned UserDefaults marker: see Rationale.
- A truncating checkpoint after every eviction or `journal_size_limit`: wider
  I/O change than asked. After the scrub the WAL starts empty; older frames in
  a reused WAL are overwritten as it cycles.

## Consequences

The first launch of this version rewrites `history.sqlite` once; on the
measured shape it shrinks from 150 MB to about 48 MB. The unused legacy
`notifications` table (about 6 MB, no current source code) is kept as is.
Encrypted backups already uploaded, Time Machine, APFS snapshots and the
SSD's physical blocks are not changed: this cleans the file's contents, not
every copy of the disk. A WAL reused after the scrub can still hold older
frames until they are overwritten.

2026-10-22 · PR: pending
