# Interface decisions

## Meetings overview — 2026-10-20

The user approved the Overview composition: recent meetings first, History
beside the screen title, and room below for future Meeting Assistant presets.
The person comes to reopen a recent note; first they see the newest five
meetings, then they can open a note or browse the complete history.

- Keep one source, selection and refresh path for overview and history.
  Why: continuing a call, deleting a meeting and opening a notification must
  describe the same meeting in every surface.
- Show five meetings in descending start time, with a date/time on every row.
  Why: the overview should be quick to scan without losing temporal context.
- History keeps every date-grouped meeting. The header stays visible while
  scrolling. Back from a note returns to the page that opened it; the Settings
  Meetings entry and direct note links use the overview as their parent.
  Why: browsing older notes must not repeatedly reset the user's context.
- Reserve extension through the overview's vertical section layout, without
  empty Meeting Assistant panels, preset settings or new persistence yet.
  Why: unfinished controls would imply that the assistant is already available.
- Use existing dark Settings tokens and the system font. Screen title is
  23 pt semibold, section headings 13 pt semibold, titles 13 pt medium, dates
  and statuses 12 pt. Titles wrap to two lines; full text is available through
  the native help tooltip. Rows have 14 pt horizontal and 13 pt vertical insets.
  Why: long Russian meeting titles need room while date/status remain readable.
- Each row is a native Button with stable hover/selection geometry. Preserve
  deletion's context menu, status restrictions and confirmation. Return to the
  list requests keyboard focus on the selected meeting, or navigation if it
  is outside the overview. No entrance or navigation animation is introduced.
  Why: keyboard use and repeated navigation should stay immediate.
- Initial loading, a successfully empty store and a failed load are distinct.
  Retry preserves the last readable list until a new load succeeds.
  Why: a storage error must not suggest that saved meetings disappeared.

The native supported window remains at least 800×600; renders inspect both
800 pt and a 600 pt Settings content pane, including long names, processing,
failure and empty states. Offscreen renders do not establish real keyboard
focus, compositor appearance or screen-reader behavior on the installed app.
On the synthetic 0.12-gray backdrop, normal title/date contrast is 11.44:1 /
5.44:1, selected title/date/status contrast is 7.34:1 and unselected failure
text is 4.53:1. Selected and hovered statuses/dates use the primary text color
to retain contrast over their brighter fills.
Five recent meetings and the future preset details remain product hypotheses
to revisit after normal use; actual presets require a separate feature.

## Case: drawer refinements

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
