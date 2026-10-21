---
id: whytap-backup-reliability
type: decision
title: Preserve the newest recoverable backup across offline edits and repeated restores
summary: Order matching-key snapshots by authenticated capture time, hash coherent content hourly and retain fresh bounded offline snapshots, preserve inert restore files, and protect repeated recovery-code display.
status: confirmed
tags: [backup, recovery, github, offline, case, synchronization]
canonical_for: [backup-reliability]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user requested an Opus 5.5 review of backup and explicitly authorized fixing confirmed serious defects beyond the initial path error.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 the user required snapshots of unique user artifacts, content hash checks at least hourly, encrypted private GitHub storage and recovery only with the saved key.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Backup/BackupViewModel.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Backup/GitHubBackupTransport.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Backup/ArtifactBackupRestore.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/Backup/BackupSimpleFlowTests.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/Backup/ArtifactBackupCoverageTests.swift
    confirmed_at: 2026-10-21
  - type: url
    reference: https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api
    confirmed_at: 2026-10-21
related: [2026-10-19-config-backup.md, 2026-10-21-backup-tagged-caches.md, 2026-10-21-backup-resume-digest.md, 2026-10-21-backup-capture-pacing.md, 2026-10-21-backup-essentials-only.md]
---

# Preserve recoverability across offline edits and repeated restores

## Context

The requested independent review identified reproducible failures: upload order
could select stale offline settings; a different recovery-key generation could
hide a valid old copy; repeated failed transfers exported full archives again;
and restored inactive files could prevent another backup or collide at restore.
The first recovery code could also disappear when leaving the screen, while
repeating Back up exposed the same code without the existing authentication gate.

## Decision

- Authenticate completion indexes with the entered recovery key and sort matching
  copies by capture date. New indexes carry the date inside their ciphertext;
  legacy indexes read the authenticated archive manifest prefix. Continue full
  digest/content verification before staging any restore. A new Mac with remote
  copies must use Restore before uploading under another key. Local encrypted
  settings history can still create a local-only key before that restore.
- Hash a coherent artifact generation at least hourly while running and idle,
  even when metadata is unchanged. Settings and key changes still trigger
  earlier checks. Exclude capture IDs, dates, build strings and encryption
  randomness from the content fingerprint. Stable inactive-file aliases prevent
  unchanged retained originals from looking different on every export. Calendar
  refresh-token rotation compares only the durable client identity, matching
  settings history; actual archives still carry the latest authorization.
- Capture changed content before contacting a destination. Once its verified
  replacement is durable, coalesce superseded unprepared automatic snapshots;
  retain resumable transfers, successful copies and recovery checkpoints. Clean
  recognized abandoned scratch generations and unindexed transfer files before
  runtime work starts. Unreadable catalogs and explicit catalog-abandonment
  markers preserve unknown archives; restore roots are never scratch cleanup.
  Resolve maintenance and restore protection before housekeeping; cleanup errors
  never skip the pause for an unreadable key-revocation journal or the remaining
  connection/recovery initialization.
  An offline destination cannot block a fresh artifact snapshot. Back off network failures
  from two to fifteen minutes (or a later GitHub rate-limit deadline). Recheck a
  transient connection failure after an offline launch without requiring open
  Settings. Only actual authentication/permission/public-repository failures
  require reconnecting. A 404 on a saved draft ID falls back to the verified
  snapshot tag or a new managed draft, while genuine permission failures stay
  fail-closed. Retry an unchanged invalid source at most hourly; a source
  change or explicit Back up retries it sooner. Validate workspace paths before large
  meeting exports and identify unsupported relative paths in the visible error.
- Schema 4 carries safe regular recording originals and repair checkpoints,
  including nested original audio, held manifests and earlier provider checkpoints. Reject active
  provider job filenames case-insensitively; park active finalize manifests.
  Regular Notify working files remain included. Preserve coexisting active/old inactive bytes under distinct
  inert names, including when reading schema 2 archives. Reserve executable
  configuration names case-insensitively. Reproducible Soniox multipart upload
  bodies are omitted while their original retained audio remains included.
- Show a first code only on the still-open view. Until it was presented, retain
  a Save your recovery code status. Later display always requires the Mac's
  device-owner authentication; repeating Back up does not reveal the code.
- Include unique Costs history through the live AIUsageStore actor’s coherent
  SQLite export and strict schema/row validation. Checkpoint its database and
  journals only when restoring an archive that includes Costs; older archives
  leave it untouched. Preserve target-only spending with deduplicated IDs and
  the store’s price-upgrade rule. An unreadable previous journal stays in the
  recovery folder and produces a warning.
- Existing Case app registrations keep their order and take priority over
  imported registrations, deduplicated by UUID and identity. Imported unrelated
  registrations retain their documented access policy. Include meeting-ready
  notification preferences and promptly signal custom-server credential edits.

## Rationale and limits

An upload timestamp describes transport order, not which settings are newer.
The date used for recovery must be authenticated by the recovery key. Pending
archives are valuable recovery data; preserve resumable work and replace only
superseded automatic pending snapshots. Content hashes avoid redundant archives
while keeping newly created offline artifacts recoverable. Retained restore
checkpoints intentionally remain available and are not a cache to prune.

Unknown paths, symlinks and unreadable current vaults remain fail-closed. No
automatic rollback dismissal or overwriting unreadable local data is authorized
by this fix. Workspace naming constraints stay conservative; explicitly tagged
disposable dependencies are handled by the related cache decision.

Seeing a code does not prove a user saved it elsewhere. Recovery still depends
on retaining that code. Provider/account configuration and permissions on the
new Mac remain separate from restoring saved values.

## Verification

Synthetic profiles and an in-memory GitHub transport exercise offline edits,
reverse upload order, legacy completion indexes, multiple recovery keys,
offline startup, advertised rate limits versus revoked credentials,
clean-profile restore, failed-authentication display, unchanged invalid inputs,
repeat restore/backup, held originals and repair checkpoints, inactive-file
coexistence, stable content fingerprints, hourly content checks without metadata
hints, fresh bounded offline artifact capture, Costs snapshot validation and
recovery, calendar token-only hourly deduplication, startup orphan cleanup,
deleted-draft resumption, and Case policy precedence.
Offscreen native fixtures cover supported widths, appearances and control states.
No real backup, provider request or user secret is used. Physical input, real
GitHub connectivity and Mac authentication require the shared installed app.

## Consequences

New schema 4 snapshots require an updated app to restore. Schemas 1–3 remain
readable. Snapshot payloads, recovery-code encoding and repository names remain
compatible; the optional encrypted index date is backward-readable. A reviewed
PR is submitted to the shared builder, which owns integration and installation.

Earlier settings-triggered checks and sooner retries after a source change are
superseded by [backup capture pacing](2026-10-21-backup-capture-pacing.md):
automatic captures start at most hourly; Back up remains immediate.
