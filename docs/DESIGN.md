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


# Notification cards — 2026-10-20

The user comes to notice a completed event and open its result. First they see
the source, title and short message. They can click to open the destination or
hover to keep the card visible while reading.

- All sources use the existing left-side card. Small notifications and the type
  selector are removed at the user's request; older icon sources become cards.
- Hover brightens the card and pauses expiry without resizing. The previous 3%
  scale overflowed the fixed panel and clipped the rounded edge. The border is
  inset, and the panel always fits the 32 pt card on unnotched displays too.
- Each source has a separate labeled Notification sound row using the existing
  native menu. Off is the default; Glass, Ping and Pop preview when selected.
  A separate row keeps long source names and the enable switch readable.
- Existing type, spacing and colors stay in use. Keyboard and VoiceOver can
  reach the sound selector; no new movement is introduced. Reduced Motion
  still suppresses transition animation. Live pointer/audio acceptance follows
  promotion of the one signed installed app; offscreen renders use fixtures.

Offscreen native checks cover 560 and 760 pt settings widths, enabled/disabled
sources and both card hover states. A pixel silhouette comparison prevents
hover growth from returning. Synthetic card text contrast is 11.44:1 for primary
and 5.44:1 for secondary text on the sampled dark backdrop. This does not claim
live pointer, VoiceOver or audio-output acceptance before installed promotion.
