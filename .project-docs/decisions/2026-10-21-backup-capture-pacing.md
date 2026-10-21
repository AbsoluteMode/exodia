---
id: whytap-backup-capture-pacing
type: decision
title: Pace automatic backup captures hourly, bound local copies and expose a pause
summary: Constantly changing sources no longer create a complete snapshot every two minutes; local archives keep only unsent work and the delta parent, captures need free disk space, and Settings shows a persistent Automatic backup switch.
status: confirmed
tags: [backup, github, disk, retention, sync, ux]
canonical_for: [backup-capture-pacing, backup-local-retention]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user asked to free disk space after automatic backup filled the Mac with complete copies; the fix task required paced captures, bounded local retention with GitHub growth accounted for, a visible pause/resume and Back up that does not silently resume sync.
    confirmed_at: 2026-10-21
  - type: trace
    reference: Installed build 1562 created 21 automatic 2.5 GB archives between 19:30 and 20:21 MSK, each with a new content fingerprint; with automatic backup off, a read-only metadata watcher saw a Notify script status file rewritten every 15 seconds and Notify history on each notification.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Backup/BackupViewModel.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Backup/BackupLocalStore.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/Backup/BackupCapturePacingTests.swift
    confirmed_at: 2026-10-21
related: [2026-10-20-backup-auto-sync.md, 2026-10-21-backup-reliability.md, 2026-10-19-config-backup.md, 2026-10-21-backup-tagged-caches.md]
---

# Pace automatic captures, bound local copies, show a pause

## Context

Every automatic generation is a complete encrypted archive of all sections
(2.5 GB in the observed profile, mostly retained meeting recordings). The
minute poll marked any metadata change as dirty and started a new generation
once two minutes had passed since the previous attempt. Working data that
changes constantly therefore produced a new archive every 2–3 minutes:

- a user-configured Notify script rewrote its `status.json` (update time and
  counters) every 15 seconds, and Notify history changed on each notification;
- clipboard history (`history.sqlite`, its WAL and images) changed on each copy;
- the Costs journal changed on each provider request.

These are genuine content changes, so the content fingerprint differed every
time. Backup did not write into its own sources: with automatic backup off the
same files kept changing, settings history did not grow during the loop, and
staging and archives live outside the probed roots.

Local retention kept every unsent archive plus the latest 30 copied ones
(about 75 GB here) with no size bound or free-space check. The only way to stop
it was a hidden preference read at launch; Back up silently re-enabled sync.

## Decision

- **Pacing.** A detected change only marks the copy as pending. An automatic
  full capture starts at most once per hour (`automaticCaptureInterval`),
  measured from the last capture attempt, changed or not; this is also the
  existing hourly content check. The hash still decides whether an archive is
  created. Back up is never delayed. Transfer retries of already captured
  copies keep their own backoff (two to fifteen minutes).
- **Disk.** A capture needs free space for one more archive (the largest known
  snapshot) plus a reserve: 10 GB for automatic captures, 2 GB for Back up.
  Otherwise nothing is exported; Backup shows the needed and available space.
  Waiting copies can still upload, which releases their parent.
- **Local retention.** Keep unsent snapshots (the freshest automatic one, any
  resumable prepared transfer and copies made for a previous destination that
  have not reached the current one), restore checkpoints and the newest copied
  archive, which is the next upload's delta parent and a fast local restore.
  Older copied archives are deleted locally after each upload and at launch,
  paused or not. Catalog entries whose archive was removed outside Whytap are
  forgotten; a vanished unsent snapshot is captured again. A prepared delta
  removed before any GitHub draft exists is prepared again. Steady state is one
  archive; the bound is about three archives while a transfer is outstanding.
- **Pause.** Settings → Backup shows an **Automatic backup** switch once a
  copy reached the destination, also while GitHub is unreachable (captures
  continue offline). Off persists across restart, cancels a running automatic
  capture or upload, including one still checking disk space, and keeps every copy. Back up then saves one copy and keeps
  sync paused; only the first created backup turns sync on. A preference change
  made outside the view is read at the next poll, without restarting.

## Why these numbers

- **One hour** is the user-required hourly content check (2026-10-21 backup
  reliability), now also the upper bound on automatic captures. It caps local
  writes at about one archive per hour instead of ~25, and settings changes are
  still saved immediately in local encrypted settings history.
- **10 GB reserve** keeps macOS usable; the observed incident left 6.8 GB free.
  The lower 2 GB margin for Back up only prevents a run that cannot finish.
- **One copied archive** is the minimum that keeps uploads incremental: without
  a local parent every upload is a complete archive. GitHub already holds every
  uploaded generation.

## GitHub growth

Uploads are deltas of changed files against the kept parent. Observed deltas
were 1–41 MB (median about 25 MB); a complete standalone upload is required
after 32 deltas or when no local parent exists (2.4 GB here). With continuous
source changes, an hourly cadence adds about (2.4 GB + 32 × ~25 MB) / 33 ≈
100 MB per upload, roughly 1–2.5 GB per day of running time, previously up to
~25 uploads per hour. Remote releases are still never deleted automatically;
pruning superseded chains is a separate destructive decision.

## Tested

`BackupCapturePacingTests` (isolated profiles, stub GitHub, injected clock and
free space): a source rewritten every minute for 150 minutes produces three
captures (the old two-minute spacing produced 76 in the same test); Back up is
not delayed; low disk skips automatic capture with no partial file and refuses
Back up below its margin, then resumes; retention keeps the delta parent and
unsent work across offline captures and uploads stay deltas; launch forgets
archives deleted by hand and releases surplus copies while paused; missing
archives and a removed prepared delta do not block sync; pause survives restart,
Back up keeps it, an external preference change applies, and pausing cancels a
running automatic capture; copies waiting for a new destination survive
retention; the switch works while GitHub is unreachable; a pause during the
disk check starts no export. Existing sync tests now advance the clock by an
hour. An independent Codex review found the last three cases; they were fixed
before submission.

## Rejected

- Excluding "noisy" files from the fingerprint: script working files are user
  data by the tagged-cache decision, and a name rule cannot tell them apart.
- A quiet-period debounce alone: a source that never stops changing would
  postpone backup forever.
- Incremental local snapshots: a format and restore-contract change; the
  transport is already delta-based and local copies are now bounded.
- A fixed gigabyte cap on local copies: deleting an unsent copy loses data and
  deleting the parent forces complete uploads; the free-space check protects
  the Mac instead.
- Automatic deletion of GitHub releases: destructive, needs its own decision.

## Supersession

This supersedes the two-minute capture spacing of the auto-sync decision, the
"settings and key changes trigger earlier checks" and "a source change retries
sooner" clauses of the reliability decision, the 30-copy local retention of the
configuration backup decision, and "Choose Back up to resume". Encryption,
verification, restore and recovery-code contracts are unchanged.
