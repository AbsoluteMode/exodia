---
id: whytap-backup-management
type: decision
title: Simple backup actions and recoverable code replacement
summary: Keep two primary backup actions, hide advanced settings, and make explicit code replacement and deletion durable without promising revocation of downloaded copies.
status: confirmed
tags: [backup, ux, recovery, encryption, deletion, keychain]
canonical_for: [backup-management]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: On 2026-10-19 the user requested two buttons for backup and restore, replacing an exposed or forgotten code, and deleting backups without creating another. The user found the No Whytap account caption unclear.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Backup/BackupMaintenance.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Backup/BackupViewModel.swift
    confirmed_at: 2026-10-19
  - type: url
    reference: https://docs.github.com/en/rest/releases/releases
    confirmed_at: 2026-10-19
related: [2026-10-19-config-backup.md]
---

# Simple backup management

## Context

The first screen exposed local block history and a confusing account caption
alongside backup setup. The user wants backup and recovery to be obvious and
needs a response to a lost or exposed recovery code.

## Alternatives

Changing only the displayed code leaves old archives decryptable. Deleting all
copies before saving a replacement risks losing the only recoverable copy.
An account identity cannot replace an independent encryption secret.

## Decision

Show Back up and Restore backup. Place management and local history in separate
collapsed disclosures. Remove the account caption. Confirm destructive actions
with their exact destination and retained local-data scope.

Replacement first verifies the new saved code, persists its key in Keychain and
a non-secret request journal on disk, then saves a full archive without delta
dependencies on the old key. Only after local and destination checks may old
full copies be removed. A durable cleanup phase survives interruption. Resume
the previous automatic setting only after cleanup completes. Deletion without
replacement removes full copies and disables automatic backup. It internally
retires the exposed key without asking the user to save a new code.

## Rationale

Failures must leave a recoverable copy and a visible, retryable state. Local
settings history and transaction checkpoints are separate recovery mechanisms,
kept on this Mac; their old history keys remain locally in Keychain. GitHub
cleanup includes drafts, requires owned archive markers and valid snapshot
tags, reads back deletion, preserves unrelated releases and works for an
accidentally public destination. Folder cleanup targets archive filenames in
the selected backup directory and rejects symbolic links.

## Comments and objections

Encryption cannot revoke ciphertext already downloaded with its code. The UI
requires stopping automatic backup on other Macs and states that other
destinations and provider trash/version history need separate cleanup. Source
credentials from a compromised archive must be rotated at their providers.
No promise of physical SSD erasure or provider retention removal is made.

## Resolution

Implement and verify with disposable profiles, real encrypted synthetic
archives and stub HTTP, then submit the reviewed commit to the shared builder.
Actual user deletion, code replacement and cloud uploads remain explicit UI
actions; development validation does not operate on user archives or secrets.

## Consequences

Forgotten codes can be replaced from a working Mac's cached key. Losing that
key and the saved code still prevents decryption of existing copies. An
unfinished request keeps automatic backup paused and blocks ordinary backup,
restore and destination changes until cleanup can be resumed.
On reopening, one idle retry continues the original request without blocking
the panel on an unrelated remote-version listing. A failed request can be
explicitly stopped: keep its files, keys and raw metadata, retire the active
code for future setup, exclude retained archives from uploads/delta bases, and
persist a warning about remaining copies. This preserves an exit when a
destination is permanently lost or the catalog is damaged. A durable finalizing
phase removes credentials and connection metadata before forgetting completion.

## Supersedes / superseded by

Refines the interface and explicit deletion policy of
[encrypted user artifact backup](2026-10-19-config-backup.md); the archive
format, account independence and local persistence contracts are unchanged.
