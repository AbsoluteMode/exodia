---
id: whytap-backup-tagged-caches
type: decision
title: Honor explicitly tagged workspace caches during backup
summary: Exclude disposable worker dependency folders identified by the cache-tag signature without weakening backup path validation or omitting nearby user data.
status: confirmed
tags: [backup, notifications, monitor, cache, python, recovery, synchronization]
canonical_for: [backup-tagged-workspace-caches]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user requested investigation and correction of the backup file-path error, automatic synchronization of settings, and a concise explanation of recovery, encryption and private GitHub storage.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Backup/ArtifactBackupStaging.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Backup/BackupViewModel.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/Backup/ArtifactBackupCoverageTests.swift
    confirmed_at: 2026-10-21
  - type: url
    reference: https://bford.info/cachedir/spec.html
    confirmed_at: 2026-10-21
  - type: url
    reference: https://docs.python.org/3/library/venv.html
    confirmed_at: 2026-10-21
related: [2026-10-19-config-backup.md, 2026-10-21-backup-reliability.md]
---

# Honor explicitly tagged workspace caches during backup

## Context

A notification worker can keep a Python virtual environment inside its owned
directory. Its interpreter links, hidden metadata and deeply nested installed
packages do not satisfy the portable archive path rules. The backup previously
walked that runtime tree and failed creation with an error that described a
restore. A local metadata-only inspection found a valid cache tag on the
dependency directory; no private contents or credentials belong in this record.

## Alternatives

- Relaxing archive path rules or following interpreter links would expand what
  an imported archive can write and still would not make an environment portable.
- Excluding every folder named `venv` or `.cache` could silently omit user data.
- A valid explicit cache tag identifies disposable data independently of names.

## Decision

Honor the Cache Directory Tagging Specification only on nested Monitor and
notification directories. Read the fixed signature from a regular, non-linked
`CACHEDIR.TAG` with a bounded read. Never follow the tag as a symlink, execute
worker code, or apply this exclusion to retained recordings. Add an aggregate
archive warning explaining that cached dependencies need rebuilding on recovery.
Use the same exclusion in the automatic change probe so cache writes alone do
not cause repeated uploads. Existing automatic settings/key capture, idle gates,
one-minute polling and two-minute attempt spacing remain in place.

## Rationale

The explicit tag declares disposable content. Python environments are recreated
on the destination rather than treated as portable application data. Scripts,
dependency descriptors, settings and working files outside the tagged folder
retain the existing complete-copy contract. Unknown hidden files, untagged
environment contents and links elsewhere still fail rather than disappearing.

## Sources

- [Cache Directory Tagging Specification](https://bford.info/cachedir/spec.html)
- [Python virtual environments](https://docs.python.org/3/library/venv.html)
- The repository sources and synthetic recovery tests listed above.

## Comments and objections

An arbitrary file named `CACHEDIR.TAG` is insufficient: an invalid signature
does not exclude anything. A linked marker cannot cause files to be omitted.
An intentionally tagged directory is excluded in full, so user-authored files
must remain outside disposable runtime folders.

## Resolution

Implement the narrow cache exclusion and test full backup/inspect/restore with
synthetic scripts, state, hidden metadata and interpreter links. Keep the safety
failure visible for content that is actually unsupported, and use wording that
does not incorrectly claim a restore was attempted during backup creation.

## Consequences

The portable archive does not reinstall worker dependencies. Recreate them and
review machine-specific paths before enabling a restored worker. This change
does not configure GitHub, upload a real backup or perform a restore on the
maintainer's profile. A reviewed source change and an installed running build
remain separate states under the shared application workflow.

## Supersedes / superseded by

Refines workspace cache handling in the existing artifact-backup decision;
encryption, recovery and transactional restore contracts remain unchanged.
