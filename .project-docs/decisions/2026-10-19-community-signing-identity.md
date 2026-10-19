---
id: community-signing-identity-2026-10-19
type: decision
title: Community builds sign with a stable self-signed certificate
summary: Community builds sign with a committed self-signed code-signing certificate whose private key lives in Doppler, so the designated requirement pins the certificate instead of the cdhash and macOS privacy grants survive updates. Without the certificate the pipeline still signs ad hoc.
status: confirmed
tags: [distribution, code-signing, tcc, sparkle, macos, opensource]
canonical_for: [community-code-signing-identity]
verified_at: 2026-10-19
sources:
  - type: trace
    reference: On 2026-10-19, after the ad-hoc 2.2.12 update, tccd logged "Failed to match existing code requirement" for Microphone and AudioCapture.
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/build-dmg.sh
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/community-signing-bootstrap.sh
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/release-provenance.py
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/upload-release.sh
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/user-release.sh
    confirmed_at: 2026-10-19
  - type: repository
    reference: Tests/SidekeyTests/PackagingRebrandTests.swift
    confirmed_at: 2026-10-19
  - type: url
    reference: https://github.com/sparkle-project/Sparkle/tree/2.9.1 (SUUpdateValidator.m, Autoupdate/SUCodeSigningVerifier.m)
    confirmed_at: 2026-10-19
  - type: trace
    reference: Two throwaway-certificate candidates (builds 90001 and 90002) with identical designated requirements and different cdhashes; full local swift test on df12312, 2,893 tests, 5 skipped, 0 failures in 55.562 seconds.
    confirmed_at: 2026-10-19
  - type: trace
    reference: Live TCC probe on 2026-10-19. A Microphone grant given to one certificate-signed build stayed authorized for a rebuild with a different cdhash, and an ad-hoc build of the same bundle ID did not match it.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Resources/community-signing-certificate.pem
    confirmed_at: 2026-10-19
related: [../project.md, 2026-10-17-community-updates.md, 2026-10-17-source-first-distribution.md]
---

# Stable code-signing identity for community builds

## Context

Community builds were signed ad hoc (2026-10-17 community updates). An ad-hoc
signature has no certificate, so its designated requirement is the build's
cdhash, which changes with every build.

macOS stores the designated requirement of the app a privacy grant was given
to and evaluates it on every access. After an update the new build no longer
satisfies the stored cdhash. On 2026-10-19, after the 2.2.12 update, tccd
logged "Failed to match existing code requirement" for Microphone and
AudioCapture (System Audio Recording): every update made users grant both
permissions again.

A Developer ID certificate would give a stable requirement, but the project
does not depend on Apple Developer membership.

## Decision

- The project has one community signing identity: a self-signed code-signing
  certificate (CN "Exodia Community Code Signing", no organization, RSA-3072,
  code-signing extended key usage, 30 years). The public certificate is
  committed as `Resources/community-signing-certificate.pem`. The private key
  lives in Doppler `sidekey/dev` as `EXODIA_COMMUNITY_SIGNING_KEY`, next to the
  Sparkle key. `scripts/community-signing-bootstrap.sh` creates both once and
  refuses to replace an existing certificate or secret. The identity was
  created on 2026-10-19: SHA-1 `39da363652f6df4b52ac950998e16c98fd39bc6b`,
  valid until 2056-10-11. `PackagingRebrandTests` pins that SHA-1.
- `.gitignore` excludes `*.pem` as signing material, with one exception for
  the public certificate. The provenance check lists untracked but not
  ignored files, so an ignored certificate would let a build sign with a file
  outside the release commit while a fresh clone signs ad hoc. A test keeps
  the exception.
- With the certificate committed, community `build-dmg.sh` signs the nested
  code, the app and the DMG with it. The key comes from the environment or
  `EXODIA_COMMUNITY_SIGNING_KEY_FILE`, is checked against the certificate
  before compiling, and is used through a temporary keychain that is deleted
  when the build ends; the user's keychain search list is not changed. The
  build verifies the designated requirement
  `identifier "<bundle ID>" and certificate leaf = H"<certificate SHA-1>"` on
  the app and on the copy in the DMG.
- Without the certificate the pipeline signs ad hoc as before, so a fork
  needs no key to build.
- The DMG manifest (schema 2) seals `code_signing`: `adhoc`, `developer-id`
  or `certificate:<SHA-1>`. Upload derives the expected value from the
  committed certificate alone, so an archive signed ad hoc or with another
  certificate cannot be published. `EXODIA_COMMUNITY_SIGNING=adhoc` and
  `EXODIA_COMMUNITY_SIGNING_CERTIFICATE_FILE` are for local builds; a
  publishing `user-release.sh` run refuses them.
- Nothing else changes for users: no notarization, Gatekeeper warnings on the
  first download stay, users never trust the certificate, and Sparkle's EdDSA
  archive verification and code-signature checks stay.
- Replace the certificate only for a leaked key.

## Why

- A designated requirement of the form `certificate leaf = H"…"` compares the
  certificate's hash; it does not require a trusted anchor. A self-signed
  certificate satisfies it without the user trusting it or changing any
  setting, and every build signed with the same key satisfies the same
  requirement, so the stored privacy grants keep matching.
- No Apple Developer membership or cost, in line with the community
  distribution decisions.
- Sparkle 2.9.1 accepts both the first switch from ad hoc and later updates:
  - With `SUVerifyUpdateBeforeExtraction`, which community builds set since
    2.2.0 (commit `21b8cc2`, in every 2.2.x tag), the archive is
    prevalidated with EdDSA; then the basic policy counts both ad-hoc and
    certificate signatures as code-signed (`SUUpdateValidator.m:191`), and
    the new app only has to have a valid signature, without a requirement
    (`:196`).
  - Without prevalidation, EdDSA passes, the new app does not satisfy the old
    ad-hoc requirement (`:347`), a valid signature is then required (`:366`),
    and the update is accepted on EdDSA (`:375`).
  - `validateConnection` sets an XPC requirement only when the host has a
    team ID (`Autoupdate/SUCodeSigningVerifier.m:448`). A certificate without
    an organization yields no team ID, as an ad-hoc signature does.
- No team ID also means no library-validation constraint matters:
  `Resources/Sidekey.entitlements` already disables library validation.
- Key custody matches the Sparkle key. Code signed with the key inherits the
  users' grants, so the key is a secret of the same class; anyone who holds
  the Sparkle key can already ship arbitrary updates.
- The DR pins the SHA-1, so a new certificate is a new identity and every
  install has to grant again; 30 years means expiry never forces that.

## What we tested

- The problem: tccd's log for the two days up to 2026-10-19 has 44 "Failed
  to match existing code requirement" entries for `com.rootwise.sidekey`
  (24 Microphone, 20 AudioCapture).
- `PackagingRebrandTests`: 17 tests, 0 failures (12.048 s). Fixtures cover
  the key check before compiling (missing or mismatched key stops the build,
  a matching key reaches the compiler), the preflight report, the refusal of
  local overrides in a publishing run, and upload refusing a manifest whose
  code-signing value does not match the committed certificate. Two tests pin
  the committed certificate's SHA-1 and check that Git does not ignore it.
- Bootstrap in key-file mode: key file 0600, certificate 0644, printed
  requirements; it refuses to run when a certificate already exists.
- Two consecutive universal candidates, both signed with a throwaway
  certificate (SHA-1 `4ef2cb47…`) through the real `build-dmg.sh`:
  A from `8c0e6b6` as build 90001, B from `df12312` (A plus the next main
  commit) as build 90002. Each build verified the requirement on the app and
  in the DMG and sealed `certificate:4ef2cb47…` in its manifest.
  - Same designated requirement, different cdhash (`074e64ca…` and
    `6bf29a5e…`), `TeamIdentifier=not set`.
  - `codesign --verify --strict --all-architectures -R` passes for B against
    A's requirement and for A against B's.
  - Controls fail: the installed ad-hoc app (a local 2.2.13 candidate)
    against A's requirement, and B against the same requirement with another
    certificate hash.
- `--installation-check` on A and B, arm64 and x86_64 (Rosetta): ok. dyld
  loads the certificate-signed frameworks under the hardened runtime without
  a team ID.
- The Security calls Sparkle 2.9.1 makes, run read-only against that
  installed ad-hoc app, A and B: both candidates are valid with all
  architectures and with nested code; A does not satisfy the installed app's
  requirement (-67050), so that one update is accepted on EdDSA; B satisfies
  A's requirement, so later updates also pass the requirement match.
- `release-provenance.py verify` with this branch's state (no committed
  certificate, so `adhoc` is expected) refuses B's archive: "archive code
  signing does not match the release signing identity" (exit 1). With the
  matching identity it passes.
- Full suite on `df12312`: 2,893 tests, 5 skipped, 0 failures (55.562 s).
- Live TCC grant on 2026-10-19. A probe app was built three times under its
  own bundle ID, `com.rootwise.sidekey.signing-probe`, so the real app's grants
  were not touched:
  - v1 and v2 were signed with the throwaway certificate (cdhash `86cbe501…`
    and `65158d86…`); v3 was signed ad hoc (`54058a90…`). None has a team ID.
  - Before the request, all three reported Microphone as `notDetermined`.
  - v1 requested Microphone and the maintainer allowed it. tccd logged the
    prompt and the new record.
  - v2 then reported `authorized` without a prompt, v3 `notDetermined`, and v2
    `authorized` again.
  - tccd logged one "Failed to match existing code requirement", for v3: the
    stored `identifier "com.rootwise.sidekey.signing-probe" and certificate
    leaf = H"4ef2cb47…"` against v3's `cdhash H"54058a90…"`. The real app logs
    the same line after an ad-hoc update.
- Production identity: `community-signing-bootstrap.sh` in Doppler mode
  stored the key and read it back. It wrote the certificate only after the
  key's public key matched the certificate's. The certificate:
  - CN "Exodia Community Code Signing", self-issued;
  - RSA-3072, sha256WithRSAEncryption;
  - CA:false, critical code-signing extended key usage;
  - valid 2026-10-19 to 2056-10-11, SHA-1 `39da3636…`.
- Not tested:
  - a real Sparkle install from the installed app to a certificate-signed
    build;
  - System Audio Recording live: it is stored and matched the same way, and
    tccd logged the same ad-hoc failure for it;
  - Keychain behavior. Keychain items of apps without an Apple-issued
    certificate are partitioned by cdhash, so the Keychain prompt after an
    update is expected to stay as it is with ad hoc.

## Rejected

- Developer ID: needs Apple Developer membership, which the community
  distribution avoids.
- Keep ad hoc and document re-granting: every update asks for Microphone and
  System Audio Recording again.
- Ask users to trust the certificate: changes system trust settings, and the
  requirement does not need trust.
- A key per build, release or machine: each one is a new identity, the same
  as ad hoc.

## Supersedes

Refines the 2026-10-17 community-updates decision: community builds sign with
the committed certificate, ad hoc only without it. The rest of that decision
stays current.

2026-10-19, PR https://github.com/AbsoluteMode/exodia/pull/33.
