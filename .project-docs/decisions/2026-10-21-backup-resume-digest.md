---
id: whytap-backup-resume-digest
type: decision
title: Confirm resumed GitHub backup parts by GitHub's digest
summary: A resumed upload accepts an existing part when GitHub's reported SHA-256 matches the local part, instead of downloading it again; new parts keep their read-back and the status counts parts.
status: confirmed
tags: [backup, github, upload, resume, progress]
canonical_for: [backup-resume-digest]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user asked to fix resumed uploads by checking already uploaded parts against the digest from the GitHub API without downloading them, and to show "part N of M" progress.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Backup/GitHubBackupTransport.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Backup/BackupViewModel.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/Backup/GitHubBackupTransportTests.swift
    confirmed_at: 2026-10-21
  - type: url
    reference: https://docs.github.com/en/rest/releases/assets
    confirmed_at: 2026-10-21
related: [2026-10-19-config-backup.md, 2026-10-20-simple-github-backup.md, 2026-10-21-backup-reliability.md]
---

# Confirm resumed GitHub backup parts by GitHub's digest

## Context

A full snapshot that includes retained meeting recordings is about 2.5 GB, so
its first GitHub upload is roughly 150 parts of 16 MiB. The maintainer's first
upload stopped at 77 parts and made no progress for hours while Settings showed
"Uploading and checking changed backup files…".

A resumed upload compared every existing part by downloading it, then downloaded
it once more as the ordinary read-back. With 77 parts that is about 2.6 GB of
downloads before the first new part, roughly half an hour on the measured
connection. Normal app restarts for local builds arrived every 12–49 minutes,
so each run spent its time re-checking old parts and was interrupted before
uploading anything new. The status gave no sign of progress.

## Decision

- When the draft already has a part with the same name, state `uploaded` and
  size, and GitHub reports `digest: "sha256:<hex>"`, the part is accepted when
  that digest equals the SHA-256 of the local part. Nothing is downloaded.
- A different digest replaces the draft's part without downloading the old
  bytes. The existing rules still apply: only an unfinished draft without a
  completion index may have a part replaced.
- An asset without a usable SHA-256 digest (older uploads, another algorithm,
  a malformed value) keeps the download comparison, now once instead of twice.
- Every newly uploaded part and the encrypted completion index are still read
  back and checked before the release is published.
- The upload reports the 1-based part and the total; Settings shows
  "Uploading backup part N of M…".

## Why

GitHub computes the digest over the asset it stores, so a matching SHA-256 is
the same evidence about the stored bytes as downloading and hashing them, at
the cost of one metadata request. The read-back for new parts stays because it
is the documented publishing contract and its cost is paid once per part. A
restart now costs only the release listing, so uploads progress across the
frequent restarts instead of starting their verification over.

## Tested

- A three-part upload interrupted after two parts resumes without downloading
  either uploaded part; only the new part and the index are read back, the
  snapshot is published once and progress reports 1, 2, 3 of 3.
- A mismatched digest deletes and re-uploads the draft's part without a
  download of the old asset.
- Missing, `sha512:` and malformed digests fall back to exactly one download.
- The Settings model shows "Uploading backup part 1 of 1…" during upload and
  no progress text afterwards.
- With digest trust disabled, the new resume tests fail (6 assertion failures),
  so they detect the regression.
- The live GitHub API returns `digest` for the maintainer's existing draft parts.

## Rejected

- Trusting the digest for newly uploaded parts as well: halves upload traffic,
  but changes the read-back publishing contract, which the user did not ask for.
- Remembering verified parts only in the local catalog: does not detect a part
  changed or removed on GitHub, and adds another durable state to recover.
- Deferring app restarts during backup uploads: the user explicitly allowed the
  builder to interrupt backup work outside meetings.
- Excluding retained meeting recordings to shrink the archive: a product choice
  about recovery data, not a transport fix.

2026-10-21 · PR: https://github.com/AbsoluteMode/whytap/pull/182
