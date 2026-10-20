---
id: one-running-copy-2026-10-19
type: decision
title: One running Exodia copy across production, beta and worktrees
summary: A common lifetime lease taken before AppDelegate starts lets only one copy run hotkeys, providers and permission flows; build-only dev commands leave other copies alone; Settings shows the app name, version and project links.
status: confirmed
tags: [installation, hotkeys, permissions, development]
canonical_for: [application-instance-ownership]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: 2026-10-19 Drop troubleshooting chat; implement free persistent signing, shortcut recovery and Deepgram Auto with Codex agents.
    confirmed_at: 2026-10-19
  - type: user-confirmed
    reference: 2026-10-19 integration chat; merge the Codex fixes, but sign with the PR #33 certificate whose key is in Doppler.
    confirmed_at: 2026-10-19
  - type: user-confirmed
    reference: On 2026-10-19 the user requested only Whytap and its display version in the Settings footer, plus whytap.ai and GitHub links, removing Production, build number, source revision and app path.
    confirmed_at: 2026-10-19
  - type: commit
    reference: 6ebf481c15b1e343f0a9d90891979b7817dc90a8
    confirmed_at: 2026-10-19
  - type: user-confirmed
    reference: On 2026-10-19 the user requested a GitHub logo, pointer and hover feedback on both footer links, visual separation from the version and balanced text sizes.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/ApplicationInstanceCoordinator.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/dev-run.sh
    confirmed_at: 2026-10-19
related: [../project.md, ../bugs/2026-10-19-permission-stability-audit.md, 2026-10-19-community-signing-identity.md, 2026-10-19-shared-working-app.md, 2026-10-19-nowplaying-adapter-shutdown.md]
---

# One running copy

## Context

Production, beta and dev builds from other worktrees could run at the same
time and compete for the same global shortcuts. A build-only `dev-run.sh`
stopped beta processes from other worktrees and registered its bundle in
LaunchServices, so the visible copy could change without the user launching
anything.

## Decision

Before AppDelegate construction, acquire a common advisory file lock across
prod, beta and worktrees. Keep its descriptor for the process lifetime, with
close-on-exec, no symlink following and owner-only permissions. Do not unlink
the lock inode. Existing legacy processes are checked through NSWorkspace.
A rejected copy offers to activate the running app and quits before permissions,
provider discovery and hotkey registration. It never kills the active take.
Old binaries launched later cannot honor the new protocol. Packaging writes the
`ExodiaInstanceLeaseVersion` Info.plist key, in both `build-dmg.sh` and
`dev-run.sh`, so a running copy can tell a lease-aware binary from a legacy one.

Build-only development commands do not kill other copies, register themselves
in LaunchServices or purge global caches. When the usual dev bundle is running,
the script assembles a separate candidate instead of replacing it. Settings
shows the actual app name and display version, followed by whytap.ai and GitHub
links that open in the browser only when clicked. At the user's request, the
footer omits channel, build number, revision and path. Detailed identity remains
available from bundle metadata for integration diagnostics. A thin rule separates
the identity from the links, all with the same 11 pt type size. The GitHub link
reuses the bundled template logo; the website has a globe. Each native Link has
a hover/press highlight, a pointing-hand cursor rectangle and a destination URL
tooltip. Cursor rectangles follow the view lifetime without global push/pop state.

## Signing is decided separately

The Codex candidate that introduced the lease (commit 6ebf481) also pinned the
maintainer's local "Sidekey Dev" certificate for releases and dev builds and
failed closed without its private key. That part was not merged. On
2026-10-19 the user chose the PR #33 community certificate, whose private key
lives in Doppler; see
[community signing identity](2026-10-19-community-signing-identity.md). Dev
builds keep using an existing local `Sidekey Dev` identity with a labelled
ad-hoc fallback.

## Limits and acceptance

Unit tests cover lock contention and release, legacy coexistence and build
identity presentation. Concurrent prod/beta startup on a real machine,
including the activation offer, is a separate live check. Binaries built
before this change ignore the lease.

## Verification

Codex's candidate passed the complete Swift suite on 2026-10-19: 2,935 tests,
5 skipped, zero failures (49.072 seconds). The result after integration with
PR #33 is recorded in the integration PR.
