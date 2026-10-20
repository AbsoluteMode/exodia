# Case: drawer refinements

## Scope and attention

This record covers the Case secrets drawer only. The existing native SwiftUI,
AppKit hit regions and transparent island materials remain the UI system.
The person comes to find or use a key. First they see search and projects;
then they can copy/edit a key, import Doppler or manage application access.

## Decisions — 2026-10-20

- The content viewport is 320 pt high; width follows the compact island.
  Why: the earlier 145 pt menu showed too little of the key list. A taller
  viewport supplies room without changing the established island alignment.
- Search is 32 pt, project rows 30 pt, key rows 28 pt, icons 22 pt.
  Why: improve readable density and pointer targets while preserving hierarchy.
- The access action reads “Доступ к ключам”, with an explanation inside.
  Why: “ИИ: нет / Подключить” did not explain what the person was granting.
- System authentication holds Case until its result is available. Pointer
  return hands control back to hover; outside click and Escape dismiss it.
  Why: the person must be able to move to Touch ID without losing the panel.
- Import is an explicit separate screen with scope, progress, cancellation,
  result/error and retry. Back is disabled during fetching.
  Why: the person should see what will be copied before starting a long read.
- Each Doppler config becomes a separate group named `project / config`.
  Why: Case has no environment selector; flattening configs would mix values.
- Import never overwrites differing values; unchanged imports are idempotent.
  Why: importing should preserve existing keys and be safe to retry.

## States and keyboard use

Search, import and access actions are always visible. Existing project
expansion and row actions remain in place and have accessibility identifiers.
The system-interaction hold does not override meeting/agent/approval policy.
The panel regains keyboard focus after authentication; Escape then returns to
tools. An outside click passes through normally. Import cancellation finishes
without committing; read, validation or conflict failure also leaves Case
unchanged and shows a sanitized message. Import values never enter view state.

## Type, color and motion

Use the existing system font and white foregrounds on the native dark surface.
Input: 12 pt medium; names/actions: 11 pt medium/semibold; messages: 11 pt.
Groups use existing 4–6 pt spacing. No new decoration or entrance animation.
The existing reduced-motion behavior remains; the hold itself has no animation.
On the synthetic 0.08-gray test backdrop, composited sRGB contrast is 7.09:1
for the search placeholder, 12.50:1 for key names and 14.92:1 for import copy.
These measurements do not establish contrast over every live native backdrop.

## Verification and open acceptance

Offscreen native renders use synthetic data and never order a window front.
Render widths are 310 pt and a wider notch-derived example; actual content
height is 320 pt. Tests cover long names, projects, access and import screens.
Automated authentication tests simulate both success and denial, without
invoking Touch ID. Physical Touch ID, returned keyboard focus and real import
remain acceptance on the one installed signed app, after builder promotion.
These are acceptance gaps, not claims of completed live verification.

Import completion, failure and cancellation do not request keyboard focus. Only
authentication restores it; a user may be typing elsewhere during a long import.


# Backup: automatic synchronization — 2026-10-20

The user opens Backup to confirm their data is protected, then open its GitHub
copy or restore it. The existing native Settings card, two actions, system font
and dark theme remain. Direction is supplied by the user: a compact status with
a backup link, without the connection caption or date. Use a 13 pt medium status
and a 12 pt GitHub link on one row, existing green only for verified sync, existing
neutral text for waiting/paused, and the existing actionable error banner.

The row never hides the link behind hover. Link participates in native keyboard
navigation, opens GitHub Releases and has an explicit accessibility label.
Status changes add no animation; busy/cancel and restore-code focus retain their
existing behavior. The scheduler waits for idle; edits during upload remain
pending. The status must not imply success from a historical upload alone.

Offscreen native fixtures cover 560 and 760 pt synchronized states, connection,
recovery code, restore, pending, syncing, paused and error without presenting a
window or uploading real data. The synchronized label and GitHub link have
6.95:1 and 11.43:1 contrast on the synthetic native dark card (sRGB #323235).
The screenshot matrix was inspected after successful render tests. Live pointer/keyboard checks remain acceptance on
the one installed app after builder promotion. Existing Settings is a dark
surface; a new light-theme system is outside this change.
