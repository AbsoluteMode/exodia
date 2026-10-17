---
id: source-first-distribution-2026-10-17
type: decision
title: Source-first Exodia without Apple Developer delivery gates
summary: Develop and publish open source with local builds, leaving the former signed DMG pipeline inactive.
status: confirmed
tags: [opensource, distribution, macos, builds, releases]
canonical_for: [current-distribution-policy]
verified_at: 2026-10-17
sources:
  - type: user-confirmed
    reference: User instruction on 2026-10-17 to stop using Apple Developer and continue simply developing open source.
    confirmed_at: 2026-10-17
  - type: repository
    reference: scripts/dev-run.sh
    confirmed_at: 2026-10-17
  - type: repository
    reference: scripts/user-release.sh
    confirmed_at: 2026-10-17
  - type: repository
    reference: docs/install.md
    confirmed_at: 2026-10-17
related: [2026-10-17-community-updates.md, ../project.md, 2026-09-10-public-installation.md, 2026-09-10-byok-and-local-builds.md]
---

# Source-first distribution

> Later on 2026-10-17, the user selected [ready-made community updates](2026-10-17-community-updates.md) as the main path. This supersedes source-only distribution and inactive binary tooling below. No Apple Developer dependency and optional source customization remain current.

Exodia's delivery target is its public source repository and a working local
build, not a notarized installer. Users clone or pull the repository and run
`./scripts/dev-run.sh --run` on their Macs. The script uses an existing local
Sidekey Dev signing identity when available, otherwise an ad-hoc signature.
This path does not require Apple Developer membership, a Developer ID
certificate or notarization. Permissions may need granting again after a build.

Apple's missing developer agreement no longer blocks source delivery. Keep
appropriate local validation, documentation and PR review. GitHub Actions stays
disabled. Publishing source does not silently publish or deploy a binary.

The old signed DMG and Sparkle publishing scripts are retained as inactive
historical tooling. They stop before build/credential/network operations unless
the maintainer explicitly selects `EXODIA_LEGACY_SIGNED_RELEASE=1`. Their signing
checks remain intact for that separately selected path. Do not turn an ad-hoc
development app into an advertised notarized installer or disable OS security
checks. Existing installed apps, bundle IDs, local data and updater compatibility
are unchanged by this distribution decision.

This supersedes the September requirement to deliver every source change through
the signed universal DMG pipeline. BYOK-first presentation and local builds remain
current. Runtime read-only/translocation checks and packaged-resource validation
remain current; a local source build still needs the complete app bundle.
