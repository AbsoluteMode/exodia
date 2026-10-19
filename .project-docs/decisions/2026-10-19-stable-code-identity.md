---
id: stable-code-identity-2026-10-19
type: decision
title: Persistent community signing and one running Exodia copy
summary: Pin a durable self-issued certificate, fail closed when its private key is unavailable, bind it in provenance, and coordinate production and beta before runtime startup.
status: confirmed
tags: [signing, permissions, tcc, installation, hotkeys, release]
canonical_for: [community-code-identity, application-instance-ownership]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: 2026-10-19 Drop troubleshooting chat; implement free persistent signing, shortcut recovery and Deepgram Auto with Codex agents.
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/code_signing.py
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/ApplicationInstanceCoordinator.swift
    confirmed_at: 2026-10-19
  - type: trace
    reference: Local TCC rejected the old production code requirement; two existing certificate-signed beta apps with different bytes satisfy the same requirement.
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developer.apple.com/forums/thread/730043
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developer.apple.com/library/archive/technotes/tn2206/
    confirmed_at: 2026-10-19
related: [../project.md, ../bugs/2026-10-19-permission-stability-audit.md, 2026-10-17-community-updates.md]
---

# Persistent code identity

## Decision

Community packages use the existing durable self-issued code-signing identity
instead of ad-hoc signing. Only its public DER certificate is committed as
`Resources/community-signing.cer`; the private key stays in Keychain. It is
valid until May 2036. Keep this certificate, the legacy bundle IDs and storage
identities across updates. No Apple Developer membership is needed.

Select the identity by certificate fingerprint. A missing key fails before
compilation, with no automatic fallback. Verify both architectures against the
certificate requirement and public SHA-256 after signing and again from the
final DMG. Schema 2 provenance binds the certificate digest, exact source commit
and immutable archive digest/size. Sparkle's independent Ed25519 archive
signature and all existing publication gates remain required.

Default maintainer dev builds use the same pinned certificate with the separate
beta bundle ID. Source users can explicitly select their own local certificate
or disposable ad-hoc signing. Do not distribute the maintainer's private key,
create identity-only requirements, change TCC databases or enable blanket trust.

Before AppDelegate construction, acquire a common advisory file lock across
prod, beta and worktrees. Keep its descriptor for the process lifetime, with
close-on-exec, no symlink following and owner-only permissions. Do not unlink
the lock inode. Existing legacy processes are checked through NSWorkspace.
A rejected copy offers to activate the running app and quits before permissions,
provider discovery and hotkey registration. It never kills the active take.
Old binaries launched later cannot honor the new protocol.

Build-only development commands do not kill other copies, register themselves
in LaunchServices or purge global caches. Settings exposes the actual channel,
version, build, revision and bundle path so users can identify a running copy.

## Limits and acceptance

The initial ad-hoc-to-certificate transition can require one permission regrant.
A stable designated requirement removes the build-hash identity change; it does
not override macOS's individual trust policies or guarantee every future TCC
decision. Self-issued signing does not supply Apple notarization. Certificate
rotation or lost private keys require a deliberate migration.

Read-only checks on two existing beta bundles established identical certificate
requirements despite changed executable bytes. Candidate unit tests cover
missing and substituted keys, non-host architecture certificate mismatch,
provenance tampering, lock contention/release, legacy coexistence and build
identity presentation. Live A-to-B permission retention is a separate acceptance
step, including physical shortcut, microphone and paste. Actual Sparkle
installation and meeting audio require their own explicit live checks; source
and signature tests alone do not establish them.

## Earlier policy

This supersedes only the ad-hoc code-signing choice in the community updates
decision. Download-on-action, archive authentication, no Apple subscription,
local builds, installation checks and source customization remain unchanged.

## Candidate verification

On 2026-10-19, the complete Swift suite passed 2,935 tests with 5 skipped and
zero failures (49.072 seconds). All 10 Python signer/provenance tests passed,
including a clean first CLI capture without a bytecode cache. Shell syntax,
customization doctor (12 checks), guidance synchronization, production preflight
and whitespace validation passed. Independent Codex review found and corrected
a removed-helper invocation, an outdated legacy cleanup assertion, and a
bytecode cache that dirtied provenance inputs. No Claude or Gemini delegation
was used. Documentation validation retains exactly 15 inherited findings and
introduces none. Packaged build and live permission retention remain separate
checks after this source commit.
