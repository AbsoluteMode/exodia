---
id: permission-stability-audit-2026-10-19
type: bug
title: Repeated macOS permissions and silent Drop registration failures
summary: Ad-hoc updates change code identity for TCC; runtime recovery and development launch behavior compound lost-hotkey failures.
status: observed
tags: [permissions, tcc, signing, accessibility, hotkeys, drop, installation]
canonical_for: [permission-stability-audit]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: 2026-10-19 Drop troubleshooting chat; the user confirmed both modes after access repair and requested a multi-agent permission audit.
    confirmed_at: 2026-10-19
  - type: commit
    reference: b112b44775910eb07f98ba9dcf3ce2e425d23140
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Hotkeys/DropHotkeyRecovery.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Tests/SidekeyTests/Hotkeys/DropHotkeyRecoveryTests.swift
    confirmed_at: 2026-10-19
  - type: trace
    reference: Local TCC reported Failed to match existing code requirement after the production update. Read-only codesign inspection confirmed cdhash-based production and certificate-based beta requirements.
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developer.apple.com/forums/thread/730043
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developer.apple.com/forums/thread/819406
    confirmed_at: 2026-10-19
related: [../project.md, ../decisions/2026-10-19-community-signing-identity.md, ../decisions/2026-10-19-one-running-copy.md]
---

# Permission stability audit

## Scope and current acceptance

Three independent agents reviewed signing, runtime recovery, and installation
coexistence. The primary agent checked the source and actual bundle signatures.
The findings table preserves the audited commit. Runtime corrections described
below are now in the source candidate; they are not installed production
2.2.13 (1465) acceptance evidence.

Removing and re-adding the production app in macOS Device Control and Data
Access, then relaunching, restored the physical hotkey. The user confirmed both
modes; diagnostics independently showed Fast with zero cleanup time and Smart
completing actual OpenRouter requests. That does not prove permission retention
after a future update.

## Findings

| Priority | Finding | Evidence at the audited commit |
| --- | --- | --- |
| P1 | Community production uses ad-hoc signing. Changed builds acquire different code identities for TCC despite the same bundle ID and installation path. | [build-dmg.sh](../../scripts/build-dmg.sh), lines 30–33 and 638–646; actual production requirement contains architecture-specific cdhash values. |
| P1 | Missing Accessibility silently prevents Drop registration, including the Carbon tap shortcut. Its loss callback belongs only to event-tap routes. | [AppDelegate.swift](../../Sources/Sidekey/AppDelegate.swift), line 1182; [HotkeyShortcutMonitor.swift](../../Sources/Sidekey/Hotkeys/HotkeyShortcutMonitor.swift), lines 66–74. |
| P1 | Failed hold-tap creation returns normally; the delegate retains a nonfunctional monitor as installed. | [SpaceHoldMonitor.swift](../../Sources/Sidekey/Hotkeys/SpaceHoldMonitor.swift), lines 312–333; AppDelegate lines 1247–1249. |
| P2 | Recovery requires app activation and a changed AX Boolean. Reopen, Settings Refresh, and a resolved Carbon collision do not independently reconcile installation. | AppDelegate lines 443–461; [PermissionsSettingsViewModel.swift](../../Sources/Sidekey/Permissions/PermissionsSettingsViewModel.swift), lines 45–48. |
| P2 | Carbon errors set a flag that no UI consumes; prod and beta can contend for the same global key. | AppDelegate lines 1250–1261; [AppState.swift](../../Sources/Sidekey/AppState.swift), hotkeyRegistrationFailed; [SidekeyAppMain.swift](../../Sources/Sidekey/SidekeyAppMain.swift), no cross-flavor ownership guard before runtime. |
| P2 | A build-only dev command stops beta processes from other worktrees and registers its own bundle with LaunchServices. | [dev-run.sh](../../scripts/dev-run.sh), lines 101–115, 138, 404–408. |
| P2 | Missing dev certificate silently falls back to ad-hoc signing. | dev-run.sh, lines 69–78. |

Production and beta intentionally have different settings and permissions. The
user's reported mismatch also involved a running brightness beta storing Smart
while production stored Fast. This was a different process and preference
domain, not evidence that corrected Fast executed Smart.

Two existing beta dev bundles have different executable bytes but identical
certificate-based requirements. Read-only `codesign --verify -R` checks accepted
both under the same rule. This proves code identity compatibility, not live TCC
continuity. The precise actor that replaced the visible running copy is unknown;
LaunchServices registration and coexistence explain a risk, not that event's
confirmed cause.

## Runtime correction in the source candidate

The implementation separates missing permission, a failed monitor, and a
shortcut collision. Carbon tap/Toggle bindings remain registered without
Accessibility. Pressing the user's saved shortcut opens the existing repair
view before a new take; Stop, release and pending Stop remain callable when
permission changes during capture. No saved shortcut, gesture, mode or provider
is rewritten. A missing hold tap throws a typed start failure, so the delegate
does not retain it as a working monitor.

Settings → Permissions and the repair view expose **Drop shortcut** status
and **Retry shortcut**. Retry can rebuild even if AX stays true. A Carbon
collision shows **Shortcut is in use**, explains the competing app/copy, and
offers **Hotkeys…** rather than requesting a permission. Input Monitoring is
offered only after the hold tap cannot be installed; it is not requested for
the user's Carbon tap binding.

Reopen, activation and Settings Refresh reconcile actual installation as well
as permission state. A repair session performs at most 120 quiet checks at
one-second intervals, stops when ready, and can be renewed by user interaction.
Polling never requests a grant or opens a repair window in the background.
Rebuilds defer while capture needs the existing Stop hook. Loss of the hold tap
itself finalizes the current capture or records pending Stop during setup;
generation guards discard callbacks from an old monitor.

`DropHotkeyRecoveryTests` cover Carbon without AX, installation/failure states,
collision classification, start-only permission gating, external grant and
unchanged-AX retry decisions, deferred rebuild and the bounded poll budget.
`PermissionsSettingsViewModelTests` cover Refresh/Retry reconciliation and
require actual shortcut installation before claiming ready. Existing Carbon
and SpaceHold tests now assert typed failures. The complete candidate Swift suite passed 2,935 tests with 5 skipped and
zero failures. This does not establish live installed-app acceptance. See the
[hotkey recovery contract](../../docs/hotkey.md#drop-permissions-and-shortcut-recovery).

## Signing and coexistence corrections

Releases are signed with the community certificate from PR #33
(`Resources/community-signing-certificate.pem`). Its private key lives in
Doppler and is imported into a temporary keychain only for the build. The app,
its nested code and the mounted DMG are verified against the certificate, and
the manifest seals `code_signing: certificate:<SHA-1>`. On 2026-10-19 the user
chose this certificate over pinning the maintainer's local "Sidekey Dev"
certificate, which the Codex candidate had proposed; see the
[community signing identity](../decisions/2026-10-19-community-signing-identity.md).
Dev builds keep an existing local `Sidekey Dev` identity with a labelled ad-hoc
fallback, so the P2 dev-fallback finding above still applies to dev builds.

Build-only dev commands no longer stop apps, register LaunchServices or purge
caches; an active destination gets a separate candidate. A common lifetime lease
coordinates production/beta/worktrees before AppDelegate starts. Settings and
conflict messages show actual build identity and application path. See
[one running copy](../decisions/2026-10-19-one-running-copy.md).

Self-issued signing is a candidate, not a guarantee for all macOS 27 TCC
services. Apple describes subsystem-specific trust policy in
[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/).
Initial migration from ad-hoc can require another grant. It supplies neither
Apple notarization nor Sparkle archive authentication. Do not weaken requirements
to only a bundle ID, edit TCC databases, disable OS protections or install
blanket certificate trust.

## Acceptance before changing normal updates

- Build A and changed B with the same signer/bundle ID; verify their designated
  requirements against each other before installation.
- In an explicit live test, grant A the intended services once, replace it with
  B, and check physical hotkey, microphone, paste and meeting audio after
  replacement and relaunch. Signature checks alone do not prove persistence.
- Exercise actual Sparkle A-to-B installation separately; retain archive
  signatures and exact-source provenance gates.
- Cover denied-to-granted without activating the accessory app, nil event tap,
  unchanged AX plus resolved Carbon collision, and concurrent prod/beta startup.

## Validation and limitations

The audit itself changed no app, permission or signing key. Runtime changes are
now in the source candidate described above; installed live dictation remains
the user's earlier acceptance of 2.2.13. Repository documentation validation has
15 inherited findings; report additions must not add findings. Signing
continuity and installed runtime recovery still need the acceptance checks
above before being described as verified.

Source candidate verification: full Swift suite 2,935 tests, 5 skipped, zero failures; 10 Python signing/provenance tests passed. Live A-to-B checks remain pending.

Integration note (2026-10-19): the candidate's `scripts/code_signing.py`, its Python tests and `Resources/community-signing.cer` were not merged. Release signing and provenance come from PR #33 and its own tests.
