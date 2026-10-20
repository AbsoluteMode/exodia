---
id: community-updates-2026-10-17
type: decision
title: Ready-made community updates without Apple Developer
summary: Publish community binaries with Sparkle signatures, defer busy relaunches and allow prepared updates on ordinary user quit unless cancelled.
status: confirmed
tags: [updates, sparkle, distribution, macos, opensource]
canonical_for: [community-update-policy]
verified_at: 2026-10-17
sources:
  - type: user-confirmed
    reference: User selected ready-made community updates and explicitly approved applying an already downloaded update on ordinary application quit on 2026-10-17; Later cancels the current installation.
    confirmed_at: 2026-10-17
  - type: repository
    reference: scripts/build-dmg.sh
    confirmed_at: 2026-10-17
  - type: repository
    reference: scripts/upload-release.sh
    confirmed_at: 2026-10-17
  - type: repository
    reference: scripts/release-provenance.py
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/Updates/UpdateController.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/Updates/IslandUpdateUserDriver.swift
    confirmed_at: 2026-10-17
  - type: url
    reference: https://sparkle-project.org/documentation/
    confirmed_at: 2026-10-17
related: [2026-10-19-community-signing-identity.md, ../project.md, 2026-10-17-source-first-distribution.md]
---

# Community updates

The normal user downloads a ready-made app; subsequent updates are discovered
through Sparkle's GitHub release feed. Download starts only on the user's Update
action. Sparkle verifies the archive with the project's Ed25519 public key and
checks the app's code-signature integrity before replacing it. This update key
belongs to the project and is independent of Apple Developer membership.
`SUVerifyUpdateBeforeExtraction` requires archive verification before parsing
its contents. The HTTPS appcast carries archive signatures; this does not claim
a separately signed XML feed.

The default local release pipeline assembles a universal arm64/x86_64 app,
signs it ad hoc and packages it without Developer ID, Apple notarization or an
Apple timestamp service. Apple-signed packaging is a separately selected legacy
mode. Community packages must retain strict signature/resource checks and a
cryptographically verified archive signature before publication. A failed or
unsigned package must never become an update item.

## Release provenance contract

Archive verification must also bind the published package to its build commit.
Commit and clean the relevant build inputs before building: `Sources/`,
`Resources/`, `Package.swift`, `Package.resolved`, `VERSION` and `scripts/`.
The pipeline must capture build-time HEAD and seal the completed DMG's SHA-256,
size, version, build, flavor, distribution mode, bundle ID and architectures in
its adjacent `<DMG>.manifest.json`. The helper exposes `capture`, `seal` and
`verify`; packaging and publication call them at the respective boundaries.
Upload-only requires that manifest and archive from the same build. Missing or
inconsistent provenance, a changed source commit or changed archive bytes must
stop publication before signing-key access or uploads. The release target must
be the verified manifest's commit. Changing HEAD requires a new build, not
relabeling an existing package. This is a pipeline contract; candidate-level
verification must still be reported separately.

## Installation and local state

First-time downloaded community apps may trigger macOS warnings; permission or
Keychain approval can be needed after a signing-identity change. Do not disable
OS protections or promise Apple notarization. Earlier installed Whytap copies
can use a different update feed, so they require a one-time manual Whytap
installation unless a separately verified bridge is published to that feed.

An idle app may install and relaunch after the requested download finishes. An
active meeting recording, dictation or agent operation instead leaves a Ready
state with Restart / Later. Restart rechecks activity and Sparkle has a final
pre-install guard. Becoming idle alone never triggers a deferred restart.
Prepared downloads may also apply when the user quits the application normally,
unless they choose Later to cancel the current installation. Downloads restored
on a later launch use the same Ready actions and ordinary-quit policy. No behavior
is promised for force quit, crashes, process kills or power loss.

Settings, keys, local history and dashboards remain outside the app bundle.
Source-customized dev builds (9999 / -dev) do not start packaged updates, which
would replace custom code. Source users retain their separate pull/merge/build
workflow with agent assistance.

This supersedes the earlier same-day source-only distribution choice and the
requirement to keep binary packaging inactive. The open-source license and the
decision not to depend on Apple Developer remain current.

## Verification scope

The focused update tests cover busy/idle decisions, resumed downloads and stale
actions. A separate native fixture using the actual Sparkle framework rejected
a tampered archive, then downloaded a correctly signed ad-hoc app, replaced
version 1 and relaunched version 2. This proves the framework's community update
path independently of a public Whytap release; public package acceptance is a
separate release check.

## Ordinary-quit decision

Sparkle 2.9.1 prepares an installer before calling its Ready user-driver
callback. Holding that callback does not disarm installation on ordinary app
exit. The user explicitly approved that behavior on 2026-10-17: a prepared,
already downloaded update may apply when the user quits the app normally.
This replaces the earlier no-install-on-quit restriction and resolves the
previous publication gate for that policy question. It does not waive package,
archive-signature or actual release acceptance checks.

Ready-stage Later replies with `skip`, cancelling the current installation
without skipping this version permanently. A later ordinary quit must not apply
that cancelled installation. Merely becoming idle does not initiate a deferred
restart. The activity guard protects against app-initiated relaunch while busy;
it does not prohibit the user from quitting their app.

This is an ordinary-quit contract, not a guarantee that an arbitrary killed
process, crash or power loss installs an update. Source evidence is the current
`IslandUpdateUserDriver.invokeLater()` implementation and Sparkle's
`SPUUserDriver.h` Ready callback contract and `Autoupdate/AppInstaller.m`
termination listener at tag 2.9.1.

The ad-hoc code-signing choice is superseded by [community signing identity](2026-10-19-community-signing-identity.md); the remaining update policy is unchanged.
