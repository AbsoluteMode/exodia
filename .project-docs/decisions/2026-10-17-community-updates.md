---
id: community-updates-2026-10-17
type: decision
title: Ready-made community updates without Apple Developer
summary: Publish community binaries with independent Sparkle signatures and defer relaunch during active work.
status: confirmed
tags: [updates, sparkle, distribution, macos, opensource]
canonical_for: [community-update-policy]
verified_at: 2026-10-17
sources:
  - type: user-confirmed
    reference: User selected the Update button downloading a ready-made build on 2026-10-17, retaining the earlier requirement not to use Apple Developer.
    confirmed_at: 2026-10-17
  - type: repository
    reference: scripts/build-dmg.sh
    confirmed_at: 2026-10-17
  - type: repository
    reference: scripts/upload-release.sh
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/Updates/UpdateController.swift
    confirmed_at: 2026-10-17
  - type: url
    reference: https://sparkle-project.org/documentation/
    confirmed_at: 2026-10-17
related: [../project.md, 2026-10-17-source-first-distribution.md]
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

First-time downloaded community apps may trigger macOS warnings; permission or
Keychain approval can be needed after a signing-identity change. Do not disable
OS protections or promise Apple notarization. Earlier installed Whytap copies
can use a different update feed, so they require a one-time manual Exodia
installation unless a separately verified bridge is published to that feed.

An idle app may install and relaunch after the requested download finishes. An
active meeting recording, dictation or agent operation instead leaves a Ready
state with Restart / Later. Restart rechecks activity and Sparkle has a final
pre-install guard. Becoming idle alone never triggers a deferred restart.
Downloads restored on a later launch also require an explicit Restart.

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
path independently of a public Exodia release; public package acceptance is a
separate release check.

## Open release decision

Sparkle 2.9.1 prepares an installer before calling its Ready user-driver
callback. Holding that callback does not disarm installation on ordinary app
exit. Ready-stage Later now replies with `skip`, which the public API defines
as cancelling the current installation without skipping this version forever.
The final relaunch guard prevents terminating active work, but does not by
itself prove that no installer survives for a later ordinary exit.

The user was asked whether a downloaded update may apply when they explicitly
quit, or must require a separate Restart action. Do not publish this candidate
until that behavior is resolved against the earlier no-install-on-quit policy.
Source evidence: Sparkle `SPUUserDriver.h` Ready callback contract and
`Autoupdate/AppInstaller.m` termination listener at tag 2.9.1.
