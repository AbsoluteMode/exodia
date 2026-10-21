---
id: notarized-releases
type: decision
title: Published team builds are notarized with a key from Whytap Case
summary: A run that publishes a team-signed Whytap has Apple notarize and staple the app and the DMG; the App Store Connect API key comes only from Whytap Case project whytap, and the manifest and upload require the notarization.
status: confirmed
tags: [distribution, notarization, gatekeeper, case, release]
canonical_for: [release-notarization]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user asked what "not notarized" means and decided to set up Apple notarization for Whytap releases, starting with a test beta build; production only on their explicit go; secrets only in Whytap Case project whytap.
    confirmed_at: 2026-10-21
  - type: trace
    reference: The installed Whytap 2.2.17 (1561), team-signed without notarization, is rejected by `spctl -a -vv` with source=Unnotarized Developer ID.
    confirmed_at: 2026-10-21
  - type: repository
    reference: scripts/build-dmg.sh
    confirmed_at: 2026-10-21
  - type: repository
    reference: scripts/notarize-submit.sh
    confirmed_at: 2026-10-21
  - type: repository
    reference: scripts/upload-release.sh
    confirmed_at: 2026-10-21
  - type: repository
    reference: scripts/user-release.sh
    confirmed_at: 2026-10-21
  - type: repository
    reference: scripts/release-provenance.py
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/PackagingRebrandTests.swift
    confirmed_at: 2026-10-21
related: [../../.project-docs/decisions/2026-10-21-developer-id-team-signing.md, 2026-06-30-metallib-sealed-resource-sequoia-gatekeeper.md, ../build-and-release.md]
---

# Notarized releases

## Context

Since the [Developer ID team signing](../../.project-docs/decisions/2026-10-21-developer-id-team-signing.md)
decision, community builds carry team `UVBKCN5PPV`'s Developer ID signature but
are not notarized. Gatekeeper therefore rejects a downloaded copy on its first
launch (`source=Unnotarized Developer ID`), and users have to find **System
Settings → Privacy & Security → Open Anyway**. The older
`EXODIA_LEGACY_SIGNED_RELEASE=1` path notarized, but took its identity from
`TEAM_ID`, skipped the team's designated-requirement checks and expected the App
Store Connect key in the environment (Doppler).

## Decision

Existing local build-only verifiers may omit `--notarization`; their expected
value remains `none`. Publishing passes its explicit expectation and still
checks the actual stapled ticket and Gatekeeper result, so this compatibility
default cannot turn an unnotarized archive into a notarized release.

- `EXODIA_NOTARIZE=1` notarizes a team-signed build. `build-dmg.sh` zips and
  submits the signed app, staples it, requires Gatekeeper's
  `source=Notarized Developer ID` and `syspolicy_check distribution`, packages
  and signs the DMG, checks the app inside keeps its ticket, then submits,
  staples and assesses the DMG (`--type open --context context:primary-signature`).
  Community-certificate and ad-hoc builds cannot be notarized and stop.
- `user-release.sh` defaults to notarization for every run that publishes a
  team build. `--build-only`, used for the builder's local refreshes, notarizes
  only with `EXODIA_NOTARIZE=1`. `EXODIA_NOTARIZE=0` is the explicit opt-out for
  publishing without it.
- The manifest (schema 3) records `notarization: none | notarized` next to
  `code_signing`. Only `team:` and `developer-id` builds can be `notarized`,
  and `developer-id` always is. A team upload expects `notarized` unless
  `EXODIA_NOTARIZE=0`, and also runs `xcrun stapler validate` and the Gatekeeper
  assessment on the DMG itself before the Sparkle key or GitHub is touched.
- The App Store Connect team API key (role Developer) lives only in Whytap Case,
  project `whytap`: `ASC_API_KEY_ID`, `ASC_API_KEY_ISSUER_ID`, `ASC_API_KEY_P8`.
  Before compiling the build lists the project's key names and names each
  missing one. Each submission runs `scripts/notarize-submit.sh` through
  `whytap case run -p whytap --only ...`.
- `notarize-submit.sh` writes the private key to a 0600 file in a private
  temporary directory, wipes it on exit or interruption, waits at most 20 minutes
  and exits 0 only for `Accepted`. It turns tracing off before reading the key
  and runs notarytool in the background, so SIGTERM removes the key at once
  instead of after the wait. A rejected submission's log is saved under
  `build/`. The legacy mode now calls the same script with its environment.

## Why

- Notarization removes the Open Anyway step; stapling the app as well as the
  DMG keeps a copied app openable without Apple's servers, the failure mode
  recorded for blocked networks in the
  [2026-06-30 metallib decision](2026-06-30-metallib-sealed-resource-sequoia-gatekeeper.md).
- Publication must not depend on remembering a flag; a local refresh must not
  wait for Apple or ask Case for a secret several times a day. Defaulting by
  step does both, and the upload gate catches a forgotten build-only flag.
- The manifest records the build's claim; the upload checks the archive as
  well, so a hand-edited manifest cannot publish an unnotarized DMG as notarized.
- Case injects the key into one command per submission, so the compiler and the
  rest of the build never see it. Its single-line field can drop the `.p8`'s
  line breaks, so the script rebuilds canonical PEM from any form that keeps the
  base64 body.
- notarytool accepts the Key ID and Issuer ID only as arguments, so they are
  visible in the process list during a submission; they identify the key but do
  not authenticate without the private key, which is only in the 0600 file.
- Keeping notarization inside the team mode keeps its designated-requirement
  checks, which the legacy mode never had.

## What we tested

- `PackagingRebrandTests` with stubs, never the real Case or Apple: the
  publishing preflight reports `notarization: notarized` and
  `notarization_credentials: case:whytap`, `--build-only` and
  `EXODIA_NOTARIZE=0` report `none`; certificate/ad-hoc builds and invalid values
  stop; missing Case keys, a missing helper and a locked Case stop before
  compiling with the missing names; complete keys reach the compiler; without
  notarization neither notarytool nor Case runs.
- `notarize-submit.sh` against a notarytool stub with a real P-256 PKCS#8 key:
  the file notarytool received was mode 600 and canonical PEM for the original,
  space-joined, line-break-free, literal-`\n` and base64 forms; the temporary
  directory was empty afterwards; output contained no key ID, issuer or key line;
  an Invalid verdict saved and summarized the log; an unsubmitted failure,
  unreadable output, an In Progress timeout, Accepted with a failing exit and a
  failed log download all exit 1; missing variables and a malformed key exit 1
  without calling notarytool. `bash -x` and inherited `SHELLOPTS=xtrace` print
  no key line. SIGTERM during a stalled notarytool exits 143 at once with the
  temporary directory empty; the same test on the earlier foreground call waited
  30 s, as did a direct shell experiment.
- An independent Codex review of the first version found the tracing and the
  deferred SIGTERM cleanup; both are fixed and covered above. It found no
  publication bypass, ordering or legacy-mode regression.
- The upload refuses an unnotarized team manifest by default, accepts it with
  `EXODIA_NOTARIZE=0` (with a warning), refuses a notarized manifest whose DMG
  fails `stapler validate` or Gatekeeper, and only then calls GitHub.
- Provenance rejects `notarized` with ad-hoc or certificate signing and
  `developer-id` without it.
- On this Mac with the real Case: `FLAVOR=beta EXODIA_NOTARIZE=1 build-dmg.sh`
  stopped before compiling and named `ASC_API_KEY_ID ASC_API_KEY_ISSUER_ID
  ASC_API_KEY_P8`.
- Getting the key: App Store Connect hid Integrations and answered 403 for API
  keys until the Account Holder accepted the updated Program License Agreement;
  afterwards it still answered 403 for the other Admin users (only the Account
  Holder has Certificates access), so the Account Holder created the team key
  "Whytap notarization" and downloaded it from a computer (the iPhone download
  failed). It was created with Admin access; Developer is enough and is the
  role to use when the key is rotated.
- With the key in Case, `whytap case run -p whytap --only ...` gave a script
  the three values; without printing them it checked that the `.p8` value is a
  P-256 PKCS#8 key equal to the downloaded file, the key ID matches the file
  name and the issuer is a UUID.
- Not yet tested at the time of writing: a real Apple submission, stapling and
  the Gatekeeper result (the build fixture stops at the compiler). The beta
  build through the builder (queue ticket 125) is the release gate.

## Rejected

- Notarize every build, including `--build-only`: local refreshes would wait for
  Apple and ask Case twice per build.
- A mode only, with no publication default: a forgotten flag would publish an
  unnotarized release again.
- Run the whole build under `case run`: the key would sit in the environment of
  the compiler and every other build step.
- Doppler or a keychain notary profile (`notarytool store-credentials`): the
  user keeps this key only in Case.
- Notarize only the DMG: the app copied out of it would need Apple's servers on
  first launch.
- Extend the legacy mode: it takes its identity from `TEAM_ID` and skips the
  team requirement checks.

README, `docs/install.md` and `.project-docs/project.md` describe notarized
releases; that change merges only together with the first public notarized
release, and Open Anyway stays documented for older downloads.

2026-10-21, branch `claude/notarize-releases-e634b7`.
