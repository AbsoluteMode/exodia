---
id: whytap-backup-reliability
type: decision
title: Preserve the newest recoverable backup across offline edits and repeated restores
summary: Order matching-key snapshots by authenticated capture time, retry pending transfers before exporting again, preserve inert restore files, and protect repeated recovery-code display.
status: confirmed
tags: [backup, recovery, github, offline, case, synchronization]
canonical_for: [backup-reliability]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user requested an Opus 5.5 review of backup and explicitly authorized fixing confirmed serious defects beyond the initial path error.
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
related: [2026-10-19-config-backup.md, 2026-10-21-backup-tagged-caches.md]
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
  copies must use Restore before creating another key.
- Transfer existing pending copies before exporting another full archive. Keep
  existing copies rather than deleting unsent data. Back off network failures
  from two to fifteen minutes, require reconnecting for account/repository
  failures, and stop automatic exports of an unchanged invalid source. A source
  change or explicit Back up retries it. Validate workspace paths before large
  meeting exports and identify unsupported relative paths in the visible error.
- Schema 3 recognizes retained inactive recording manifests and regular Notify
  working files. Preserve coexisting active/old inactive bytes under distinct
  inert names, including when reading schema 2 archives. Reserve executable
  configuration names case-insensitively. Reproducible Soniox multipart upload
  bodies are omitted while their original retained audio remains included.
- Show a first code only on the still-open view. Until it was presented, retain
  a Save your recovery code status. Later display always requires the Mac's
  device-owner authentication; repeating Back up does not reveal the code.
- Existing Case app registrations keep their order and take priority over
  imported registrations, deduplicated by UUID and identity. Imported unrelated
  registrations retain their documented access policy. Include meeting-ready
  notification preferences and promptly signal custom-server credential edits.

## Rationale and limits

An upload timestamp describes transport order, not which settings are newer.
The date used for recovery must be authenticated by the recovery key. Pending
archives are valuable recovery data; preventing new redundant exports avoids
unbounded failure-driven growth without deleting old copies. Retained restore
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
clean-profile restore, failed-authentication display, unchanged invalid inputs,
repeat restore/backup, inactive-file coexistence, and Case policy precedence.
Offscreen native fixtures cover supported widths, appearances and control states.
No real backup, provider request or user secret is used. Physical input, real
GitHub connectivity and Mac authentication require the shared installed app.

## Consequences

New schema 3 snapshots require an updated app to restore. Schemas 1 and 2 remain
readable. Snapshot payloads, recovery-code encoding and repository names remain
compatible; the optional encrypted index date is backward-readable. A reviewed
PR is submitted to the shared builder, which owns integration and installation.
