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
- Use the current adaptive Settings tokens and the system font. Screen title is
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
In the original feature fixture on a synthetic dark 0.12-gray backdrop, normal title/date contrast is 11.44:1 /
5.44:1, selected title/date/status contrast is 7.34:1 and unselected failure
text is 4.53:1. Selected and hovered statuses/dates use the primary text color
to retain contrast over their brighter fills.
Five recent meetings and the future preset details remain product hypotheses
to revisit after normal use; actual presets require a separate feature.

Combined with adaptive Settings, native overview/history/error fixtures also render in light and dark appearance on the matching page surface. Semantic token contrast remains covered by MacSettingsThemeTests.


## Settings appearance and switches

### Purpose and attention

Settings is a working surface for configuring providers, shortcuts and optional
features. The user first identifies the selected section, then reads each setting
and its current value, then changes that value without losing context.

### Direction and layout

- Use iOS inset groups within the existing macOS sidebar window. Groups describe
  related settings. In API & Models, independently configured functions have
  separate contours and a 10 pt gap, so their setup states do not run together.
- Keep the current tabs and navigation. A small colored SF Symbol tile makes
  sections recognizable without changing their names or order.
- Use 14 pt group corners, 14 pt row insets and 12 pt vertical row padding.
  Shared dividers are one point, inset on both sides, with 2 pt breathing room
  above/below. Long descriptions wrap instead of shrinking the control.
- The window keeps its 960 pt minimum width; verify the minimum and a larger
  1280 pt window. This desktop window does not have a phone-width layout.

### Typography and color

Use the system font: 22 pt semibold page titles, 13 pt regular row names,
11.5 pt explanations, 12 pt semibold group captions. Keep Cyrillic legible.

`MacSettingsTheme` owns dynamic AppKit colors shared with SwiftUI. Light surfaces
are grouped grey with white groups; dark surfaces are charcoal with lighter
groups. Text, separators, fields, status text and menu labels all resolve for
the current system appearance. The open Settings window follows appearance
changes without saving an override or changing any feature preference.

Blue labels indicate navigation/actions; filled blue actions keep white-label
contrast. Green/red/amber status text has separate light and dark values.
`MacSettingsThemeTests` measures normal text and status labels at 4.5:1 or better
against their intended surfaces. Disabled controls are explicitly dimmed.

An unconfigured model function uses a static orange outline and a soft 5 pt
outer glow (12% light, 18% dark). The outline has at least 3:1 contrast on both
the row and page surface; the glow is decoration, never the only boundary.
The normal `Choose a model` action stays visible. `Not set` and warning triangles
are removed from these rows; actual error explanations and recovery actions
remain text. Native accessibility exposes `Needs setup`; the picker group also
explains that a model and its provider key are required. Reduce Transparency
removes the glow while preserving the solid contour. There is no pulse or
attention animation; Reduce Motion also disables programmatic row scrolling.

### Switch reference and behavior

The user supplied `toggle-switch-glass.tsx` on 2026-10-20. Adapt its green track,
white pill thumb, short spring, press feedback and drag-to-set behavior directly
in SwiftUI; the native app does not acquire a React runtime or npm dependencies.

- Settings switch: 60 × 33 pt with a 35 × 28 pt thumb. The island retains its
  compact 30 × 18 pt blue switch because it must fit its existing control row.
- Click/Space toggles. Left/Right select Off/On on the focused control. Drag
  settles at the nearest endpoint; a quick swipe uses its projected direction.
  A drag commits once on release. Escape cancels a drag.
- External binding changes remain authoritative. Disabled controls cannot change
  state, including through accessibility. A native Toggle accessibility proxy
  exposes the setting name and state, with a visible keyboard focus ring.
- Only thumb position/press scale animate: a short spring (0.22 s response,
  0.88 damping) and a 0.1 s press transition. Reduce Motion removes these
  movements; Reduce Transparency uses an opaque white thumb. Native glass is
  guarded for macOS 26, with a simple highlighted thumb on macOS 14/15.

### Embedded surfaces

The island stays dark. Toolbox embeds actual island editors inside explicitly
dark previews; the Toolbox navigation, captions and catalog follow the Settings
theme. This keeps the preview faithful and prevents white overlay text from
disappearing on a light settings surface. API hints and key/model sheets follow
the parent window's system appearance.

### Verification and hypotheses

Offscreen render tests use temporary fixture stores and offline providers and never
show a window, start an app runtime, record audio or request permissions. They
cover both appearances at 960 × 560 / 1280 × 760 pt, Cyrillic descriptions,
disabled switches, fields and notes. A hosted-window test changes appearance
without rebuilding its root. Screenshots are visual evidence only; live keyboard,
drag and Reduce Motion/Transparency remain explicit acceptance checks in the shared
installed app. Older-macOS fallback needs device acceptance.

### Decision log

- 2026-10-20 — Follow system appearance automatically: the user asked for light
  and dark support, so a separate theme preference adds unnecessary state.
- 2026-10-20 — Adapt the supplied component to SwiftUI: existing Settings is
  native, and retaining native focus, bindings and accessibility matters here.
- 2026-10-20 — Group rows with consistent insets: this brings the requested iOS
  settings rhythm while preserving the established macOS navigation.
- 2026-10-20 — Replace unconfigured model alarms with a warm contour and soft
  glow: the user requested a calm setup cue, plus clearer separation of rows.
  Each model function gets its own contour because its routes form one setting.

## Case: drawer refinements

### Scope and attention

This record covers the Case secrets drawer only. The existing native SwiftUI,
AppKit hit regions and transparent island materials remain the UI system.
The person comes to find or use a key. First they see search and projects;
then they can copy/edit a key, import Doppler or manage application access.

### Decisions — 2026-10-20

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

### States and keyboard use

Search, import and access actions are always visible. Existing project
expansion and row actions remain in place and have accessibility identifiers.
The system-interaction hold does not override meeting/agent/approval policy.
The panel regains keyboard focus after authentication; Escape then returns to
tools. An outside click passes through normally. Import cancellation finishes
without committing; read, validation or conflict failure also leaves Case
unchanged and shows a sanitized message. Import values never enter view state.

### Type, color and motion

Use the existing system font and white foregrounds on the native dark surface.
Input: 12 pt medium; names/actions: 11 pt medium/semibold; messages: 11 pt.
Groups use existing 4–6 pt spacing. No new decoration or entrance animation.
The existing reduced-motion behavior remains; the hold itself has no animation.
On the synthetic 0.08-gray test backdrop, composited sRGB contrast is 7.09:1
for the search placeholder, 12.50:1 for key names and 14.92:1 for import copy.
These measurements do not establish contrast over every live native backdrop.

### Verification and open acceptance

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
