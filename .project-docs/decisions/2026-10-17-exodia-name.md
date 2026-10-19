---
id: exodia-name-2026-10-17
type: decision
title: Exodia product and repository name
summary: Rename the public repository and user-facing product while retaining existing local identity and data locations.
status: stale
tags: [branding, repository, compatibility, macos]
canonical_for: [historical-exodia-name]
verified_at: 2026-10-17
sources:
  - type: user-confirmed
    reference: User request on 2026-10-17 to rename the repository and project to exodia.
    confirmed_at: 2026-10-17
  - type: url
    reference: https://github.com/AbsoluteMode/exodia
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/BuildConfig.swift
    confirmed_at: 2026-10-17
related: [../project.md, 2026-10-19-whytap-name.md]
---

# Exodia name

Superseded on 2026-10-19 by the [restored Whytap name](2026-10-19-whytap-name.md).
The text below records the earlier rename and is not current naming guidance.

The product name is Exodia and its public source repository is
`AbsoluteMode/exodia`. The former public `AbsoluteMode/whytap` repository was
renamed in place, preserving its issues, pull requests, history and visibility.
The source checkout's `public` remote uses the new URL. The separate private
`rootwise-team/sidekey` repository is unchanged.

Use Exodia for app display names, new bundle filenames, current user guides and
release URLs. Retain the internal Sidekey Swift targets, bundle identifiers,
Keychain services, local storage folders and saved preference keys. These
identifiers locate existing data and macOS permission grants; changing them is
a separate migration, not a cosmetic rename. Historical records and migration
identifiers can retain earlier names.

The repository rename does not replace previously published binaries or the
installed production app. A new Exodia release requires its own completed build,
signing and distribution checks.
