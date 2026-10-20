# Interface decisions

## Screenshot editor polish — 2026-10-20

The person comes to mark a screenshot and copy or download it quickly. First
they see their crop and a single toolbar row. Next they choose a tool, adjust
its settings beside it, and finish with Copy/Return or Download.

- Tools, contextual controls and export actions share a 42 pt horizontal row.
  Why: the user explicitly rejected settings on a second row. Keep system
  typography, adaptive popover material and semantic accent/label colors.
  Selected tools retain label-color text on an accent wash; accent-blue text
  on that wash had insufficient contrast in the native dark snapshot.
- Show only settings relevant to the active tool. Color/width use existing
  per-tool preferences; the label field is 160 pt. Why: the screenshot is the
  workspace, and tool configuration should stay nearby without a permanent form.
- Copy remains the accented primary action. Download has a downward arrow and
  explicit text, writes directly to Downloads and keeps the editor open with
  its actual filename. Why: file destination and success must be visible without
  a Save dialog or interpreting a Share symbol. Name collisions never overwrite.
- Return/keypad Enter copies and closes after selection; during Blur the command
  waits for the completed patch; during Download it waits for the file. Without a crop it copies the whole display and closes in one action.
  Return in the label field also copies/closes. Typing is preparation;
  click the screenshot to place the label first. The placeholder/help explicitly
  say that an unplaced label is discarded, keeping the requested one-Return finish. Failed processing stays open.
- No entrance, resize or tool-switch animation delays input; reduced motion uses
  the same immediate behavior. Busy state disables mutating/export controls and
  reports processing; Escape stays available. Copy and Download encode off the
  main thread. Fast Vision regions plus a bounded isolated-glyph atlas avoid accurate
  OCR’s per-build cold start; dark crops are normalized for detection only.
  Copy text retains accurate OCR as a separate action.
- Text masks have 3 px padded, subtly rounded edges; strength follows each text region’s height,
  rather than the selected area's dimensions or the median of other labels.
  Overlapping masks apply stronger blur last. Entire area covers every pixel.
  Why: avoid oversized smears while preserving the existing text/number contract.

Native offscreen fixtures cover the real AppKit toolbar in both appearances,
all main tool states and 640/768/1024 pt available widths; generated images cover region detection, crop/annotation
alignment, flattened pixels, unique downloads and keyboard commands. These
checks do not establish live capture permission, real clipboard delivery, physical
keyboard focus or perceived smoothness in the installed application. Those remain
acceptance after the designated builder promotes the reviewed source.

## Searchable model selection — 2026-10-20

The user comes to choose a model without scrolling a long catalog. First they
see a focused search field, then matching model IDs under their provider.
The closed control retains the shared 30 pt popup label and existing widths.

- Open a 440 pt native popover with a fixed search band, 300 pt scrolling list
  and fixed result-count/Refresh models/Other model ID footer. Why: typing and
  recovery actions must remain reachable in a large catalog.
- Match every query term in any order, ignoring case, diacritics, width and
  separators. Split letters/digits: `qwen 27` and `qwen27` find
  `qwen/qwen3.8-27b`. Prefer contiguous matches within each provider, preserving
  the catalog order for ties. Why: remembering a family and size should suffice.
- Keep provider headings, current-selection checkmarks, cached-refresh failures
  and disabled unsupported models. A two-line model label and full-ID tooltip
  handle long names. Exact account/model pairs remain distinct.
- The native search field owns normal editing and IME composition. Up/Down
  moves through enabled results and scrolls them into view; Return selects.
  Escape clears the query, then closes; outside click dismisses. Focus returns
  to the originating control. There is no new animation.
- Empty results offer Clear search and exact-ID entry; absent providers offer
  Add API key. Refresh is single-flight and keeps the query. Search/arrow
  movement alone never selects or checks a model. An explicit pick uses the
  existing verification and route-preservation path.

Offscreen native fixtures cover the 440 pt picker in both appearances, filtered,
empty, absent-provider, stale-catalog and long/disabled-row states. Search and
native editing-command tests cover matching, stable ordering, account identity,
keyboard bounds and IME Return. These checks do not prove physical focus,
popover dismissal or VoiceOver on the installed app; those remain acceptance.
The interpretation that a family plus size is the useful search input follows
the user's example; typo correction and model aliases are outside this change.

## Model disclosure — 2026-10-20

The user chose compact function rows that open their settings on click. The
person comes to see which models each function uses; first they see the function
and selected model IDs, then they can open that function to change its routes.

- Closed headers are 48 pt high, with a 116 pt name column, a single-line model
  summary and a reserved 12 pt disclosure arrow. Paired speech/text routes show
  their model IDs together, separated by a dot, truncating in the middle.
  Full provider/model labels remain available through native help; accessibility
  announces both model IDs and expansion/setup state. Why: model names must not
  move other rows or cause uneven header heights.
- A click anywhere on the header, Space or Return opens settings directly below
  it. One function is open at a time; another click or Escape closes it. Escape
  returns focus to that header. No expansion or entrance animation is added.
  Why: configuration should stay compact and connected to the chosen function.
- The summary stays visible while open. The expanded controls use Speech/Text
  labels for paired routes and Model for a single route. Transport labels such
  as real-time, recorded and LLM with tools are removed from the main list.
  Model filtering still follows the unchanged internal feature modes.
- Selected model IDs are derived directly from the saved routes. Changing or
  removing a route updates the summary; opening/closing rows writes no route.
  Unselected routes show Choose a model and retain the existing warm contour.
- Actual errors, language warnings and recovery actions stay visible even when
  collapsed. Configuration-error links and Show expand the target function
  before scrolling to its stable group ID. Why: disclosure must not hide a
  required repair or break runtime links into Settings.
- Existing system typography, adaptive colors, card contours and 10 pt gaps
  remain. Expanded model fields have equal widths, with reserved space for the
  optional provider menu. Checking… and its progress indicator remain visible
  below the header even when closed; repeated checks are ignored until the
  pending check completes. Native menu behavior is retained.

Offscreen fixtures cover 600/900 pt content panes, both appearances and closed
and open paired rows, using temporary stores, synthetic keys and offline
providers. They do not establish physical keyboard focus, VoiceOver or native
menu operation on the installed app; those remain promotion acceptance.

## Independent subtitle models — 2026-10-20

The user requested both subtitle model roles in Settings and explicitly chose
an independent subtitle LLM. The existing compact disclosure stays: one
Subtitles header summarizes both model IDs and opens Speech then LLM selectors.
Text Translation retains its own row and route. Why: changing the text
translator must not change the model used by live subtitles.

Keep 48 pt headers, existing equal-width model controls, theme colors, keyboard
disclosure and visible errors. Both subtitle error links open this same group;
Speech and LLM prefixes identify the required repair. No new animation is added.
Existing subtitles keep their prior model/provider once at migration; clearing
the new LLM never reconnects it to Translation. Offscreen fixtures cover closed
and expanded Subtitles at 600/900 pt in both appearances. Native menu/focus and
real provider output remain acceptance in the shared app after promotion.

## Screenshot permission — 2026-10-20

The user requested a screenshot access entry in Settings -> Permissions.
Keep the existing permission group, MacRow, MacPill and MacButton: this is one
more permission in the same workflow. The person first sees Screen Recording,
then Allowed/Not allowed, then Allow/Open. A persistent explanation names
screenshots and tells them to finish current work before a macOS-requested reopen.

Only clicking Allow requests access. Open manages an existing grant; a denial
opens the system privacy pane. Returning to the app and Refresh reread access
without prompting. A missing grant never blocks launch or Drop. Existing native
button focus, keyboard activation, semantic colors and scroll behavior apply;
there is no new hover-only action or animation. A denied Bool cannot distinguish
an unasked grant from a previous denial, so use Not allowed rather than Denied.

Offscreen native fixtures cover allowed/missing access in light/dark at 739 and
1059 pt content widths (the existing 960 and 1280 pt Settings shells). Real TCC
prompts, keyboard focus and post-promotion refresh remain installed-app acceptance.


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
- Keep the current tabs and navigation. Sidebar rows use text alone, following
  the user's 2026-10-20 request to remove the colored icon tiles.
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

## Text-only Settings sidebar — 2026-10-20

The user requested removal of the sidebar icons and animation on hover.
Keep section names, order, 220 pt sidebar width and 38 pt row hit targets.
Removing the icon and gap gives labels 180 pt instead of 144 pt, without
changing text size or moving any row during interaction.

- Hover fades the rounded background in/out over 140 ms with ease-out. It
  signals which row is clickable, accepts reversals immediately, and affects
  only background opacity. Text and hit geometry stay fixed.
- Unselected rows use the existing adaptive hover color at 85% opacity; the
  selected blue row gets a 10% white overlay (white-label contrast 4.67:1).
  Selection remains recognizable during hover.
  FAQ and Quit use the same feedback. Existing navigation highlights remain.
- Reduce Motion makes the hover response immediate. Native Button actions,
  keyboard access and focus are preserved. No function requires hovering.

Offscreen native Settings fixtures cover the minimum 960 × 560 pt and larger
1280 × 760 pt window in both appearances. Physical hover, focus/VoiceOver and
system Reduce Motion acceptance remain on the shared installed app after
builder promotion; the feature session does not launch another app instance.
Offscreen cacheDisplay captures intermittently omit sidebar glyphs, including
the selected label on the unmodified base. These images establish layout only;
check every label in both appearances on the installed app.

## Case and persistent hover menus — 2026-10-20

The person comes to find a key, then use it or configure access. The existing
native SwiftUI/AppKit surface, notch-derived width and 320 pt Case viewport
remain. Search, projects and keys get the available space.

- Connected apps appear as their icons, without a status lamp or text caption.
  The icons describe saved Case registrations, not whether a process is running.
  Clicking an icon opens access settings; an empty state has a link icon for
  setup. Native help and accessibility name the app and action. A horizontal
  strip supports more registrations without widening the drawer.
- Access explains Approve/Bypass in one line. The Touch ID requirement and
  shared-terminal Bypass consequence remain concise and visible where relevant.
  Back uses white at 88% opacity, matching the island's navigation.
- Case has no Doppler import action, integration, or background synchronization.
  The requested one-time transfer is operational work; removing the integration
  does not establish that the user's real keys were transferred.
- Every explicitly opened inline menu stays open through pointer exit, including
  Case authentication success/denial. Back and normal selection retain their
  existing navigation; outside click or bare Escape dismiss the menu. The outside
  click still reaches its target. Native submenu and file-picker interactions
  temporarily suspend dismissal. Activity/preemption policy still wins.
- Root tools retain hover dismissal. Hardware brightness glances retain their
  two-second timeout and leave keyboard focus in the user's app. Entering the
  glance converts it to an ordinary persistent menu. Timers cannot dismiss an
  explicitly opened submenu. Search keeps its own focus behavior.

No new entrance animation or decoration is introduced. Existing density, system
font and motion settings remain. The app icons are 18 pt in 28 pt targets.
Offscreen native fixtures use synthetic names and values, widths 310/390 pt,
320 pt content height and a dark backdrop. They cover connected icons, long
names and access modes without launching an app runtime or requesting Touch ID.
White navigation has 14.28:1 contrast and the explanation 13.36:1 over the
synthetic 0.08-gray backdrop; the 60% footer has 7.12:1 there. These measurements
do not establish contrast on every live glass backdrop. Native event classifier
checks cover outside/inside clicks and bare/modified Escape; pure state checks
cover every inline mode, pointer exit, stale hover zones and brightness glances.

Actual keyboard focus, compositor appearance, menus/file pickers and physical
Touch ID remain acceptance on the one signed installed app after promotion.


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

## Planner: tasks and calendar — 2026-10-20

The person comes to write down a task or find the next appointment. First they
see the task list or selected day, then they can add/edit local content or join
a connected meeting. Calendar retains its native sidebar and detail pane.
The user subsequently selected a compact inline To-do list; that supersedes
the original window entry for the To-do catalog action (details below).

- Calendar opens a 980×680 window, minimum 820×560, with extended task management
  still available in its sidebar. To-do opens in hover. Why: the month grid needs
  desktop space; quick task capture needs a small surface. Saved slots stay intact.
- Use the system font, native controls and semantic surfaces. Titles are 28pt
  bold, object names 13pt, metadata 11–13pt. MacSettingsTheme.text2 keeps metadata
  readable in both appearances; the selected date uses the shared #0064D2 fill
  with white labels. Why: both Russian text and calendar counts remain legible.
- Task entry stays above the active/completed list; Return adds it. Search, edit,
  complete/reopen and delete actions are visible without hover. Delete asks first.
  Why: this is a short repeated workflow, so secondary actions cannot shift rows.
- Calendar retains a month grid and a scrolling day agenda. Minimum height leaves
  at least one agenda row; remaining events scroll in place. Local event editing
  uses a sheet, external event details offer Join/Open original. Why: the source
  calendar remains authoritative for connected events in the first version.
- A sheet remains attached when another tool hotkey opens Planner. Account sign-in
  shows browser progress, cancellation and actionable error text. Closing the main
  window ends polling. Why: navigation and closing must not lose drafts or leave
  hidden network work running.
- Validation errors belong to their editor and disappear with it. Moving Start
  keeps the event duration, and All day preserves its prior times of day. Notes
  and day counts have explicit accessibility labels. Why: correction and date
  changes must not contaminate another editor or silently discard entered times.
- A registered build asks the user to select a calendar provider and sign in. Native
  client settings are advanced setup; an unregistered build exposes that setup
  honestly. Why: owner registration is a packaging responsibility, not a repeated
  task for every account holder.
- Planner/To-do visibility or a retained new-task draft defers update restart and restore.
  Backups continue to capture saved data. Why: protecting edits must not pause all
  backup synchronization while someone keeps their calendar open.
- No additional motion is introduced; native focus, keyboard shortcuts, sheets
  and accessibility labels remain. Why: repeated editing should stay immediate
  under Reduce Motion as well as ordinary settings.

Offscreen synthetic fixtures cover empty/populated tasks, the month/day calendar,
connect and event editors, at 820 and 980pt in both appearances, plus calendar
visibility-limit feedback in both appearances. Measured metadata contrast is 6.62:1 on the light surface; white selected-date
labels on the shared blue fill are 5.59:1. Separate Codex and Claude Opus 5.5 reviews
inspected layouts and data/backup contracts. The Claude review led to repairs in
token backup behavior, editor errors, date editing, accessibility and packaging
configuration discovery. Real OAuth, system permissions, VoiceOver, physical keyboard/focus and
compositor appearance require acceptance on the one installed application. The
priority of a unified calendar over separate provider windows remains a product
hypothesis to revisit after ordinary use.

# Notification cards — 2026-10-20

The user comes to notice a completed event and open its result. First they see
the source, title and short message. They can click to open the destination or
hover to keep the card visible while reading.

- All sources use the existing left-side card. Small notifications and the type
  selector are removed at the user's request; older icon sources become cards.
- Hover retains the 3% enlargement, brightness and paused expiry. It grows left
  and down from the top-trailing corner, preserving top alignment and the 8 pt
  island gap. Transparent panel overflow fits the whole card; the click region
  follows its transformed size. The inset border stays within the rounded shape.
- Each source has a separate labeled Notification sound row using the existing
  native menu. Off is the default; Glass, Ping and Pop preview when selected.
  A separate row keeps long source names and the enable switch readable.
- Existing type, spacing and colors stay in use. Keyboard and VoiceOver can
  reach the sound selector. Reduce Motion suppresses hover growth and transition
  animation. Live pointer/audio acceptance follows
  promotion of the one signed installed app; offscreen renders use fixtures.

Offscreen native checks cover 560 and 760 pt settings widths, enabled/disabled
sources, idle/hover/reduced-motion card states. Pixel bounds prove that the
card really enlarges while remaining inside its panel with rounded edges. Synthetic card text contrast is 11.44:1 for primary
and 5.44:1 for secondary text on the sampled dark backdrop. This does not claim
live pointer, VoiceOver or audio-output acceptance before installed promotion.

Combined integration also renders notification Settings in both system appearances using the shared adaptive tokens; island cards retain their dark appearance. The earlier Backup fixture measurements above describe that original dark fixture, while current shared Settings follows the Settings appearance section.


## Case Connect, project scope and search — 2026-10-20

The person comes to find a key or give an agent access to it. First they see
key search, their projects and the connected app icons. Then they can use a
key, add one explicitly, or choose Connect and review an agent's rights.

Keep the existing native SwiftUI/AppKit surface and 320 pt viewport. The user's
chosen flow is Connect → agent → rights, and an existing icon → that agent's
rights. No alternative composition or decorative screen is needed.

| Component | Behavior and reason |
| --- | --- |
| Search | Always searches key names/descriptions; Return cannot create a key. New key name/value fields appear separately after + Key, so a search cannot become a write. Empty results say Keys not found; projects are contextual headings, never search hits. |
| Connected icons | Open the selected registration directly. Connect stays visible beside the horizontally scrolling strip, including when empty. Codex/OpenAI uses blue, Claude/Anthropic orange, Cursor a white halo. Hover/focus change color and glow without changing geometry; keyboard focus has an outline. Reduce Motion removes the short opacity/color transition. |
| Client picker | Discovers installed clients only after Connect. Shows loading, an explicit empty message and Choose program. Selecting a client opens a draft; nothing is registered until Connect on the rights screen. |
| Rights | Default Accept asks before use; Bypass allows use without prompts. All projects explicitly includes future projects; Selected shows checkboxes and denies unchecked projects at the broker. Existing per-project overrides remain visible/editable. An empty saved scope closes access; a new connection needs at least one project or All. |
| Save | One transaction stores mode and scope; registration, widening access and enabling Bypass require Touch ID. Pending authentication disables edits and Back. Failure preserves the draft and explains recovery; connector errors remain visible after registration, with Retry setup reusing the same registration and rights. |
| Back / disconnect | Back discards unsaved rights. Disconnect revokes access before editing client config. Existing island outside-click and Escape dismissal still apply. |
| Approval | The request shows the command, app, project and key names. A Stepper changes temporary Bypass to 1–240 minutes; the button and physical A use that value. Default 15 is restored for the next request. Grants are scoped to app/project and disappear at expiry, policy change or restart. |

Display metadata and project sections are rebuilt when the vault changes and
reused for renders. Search only filters/ranks metadata; values never enter its
index. The list is lazy so closed projects and offscreen rows do not create a
full hierarchy on every keystroke. Touch ID remains the opening gate.

Validation uses offscreen native fixtures, synthetic names and values, and fake
authentication. The installed application is reserved for acceptance through the
shared builder. These fixtures do not prove live keyboard focus or glass
contrast on every desktop; those remain runtime acceptance checks. The user's
reported lag may have been concurrent build load, not a confirmed app fault.


## Compact To-do in hover — 2026-10-20

The user chose one small list, with immediate capture and completion. First see
active tasks and the input; History is secondary. This replaces only the To-do
catalog entry's former large-window direction.

- Use the existing island width (including 310pt) and a 290pt content band inside
  the shared glass drawer. A 26pt header contains Back, To-do and History. Rows
  scroll within the panel; titles use 12pt, history dates 10pt. Why: the list stays
  compact and its native pointer band matches visible content.
- Input has a stable 32pt height and a visible focus outline. Return adds; empty
  input does nothing; invalid input or failed persistence keeps the draft.
  Opening the tool explicitly acquires keyboard focus, ordinary hover does not.
  Why: capture takes one action without stealing focus from the user's editor.
- Clicking the entire task row toggles completion. Completed rows stay at the
  bottom during this opening, with a checkmark and strikethrough; the next opening
  shows active tasks only. History sorts completed tasks by completion time and
  supports reopening. Why: accidental completion is reversible before closing.
- History shows completion date and local time. The optional persisted timestamp
  decodes old archives without migration; legacy unknown times stay explicitly
  unknown. Reopening clears the timestamp, and a later completion writes a new
  one. Why: history must describe an actual action rather than an invented date.
- Rows keep fixed geometry on hover. A native help tooltip exposes the full title;
  accessibility labels retain the full title and completion state/date. Native
  buttons and text input provide keyboard access. Why: long titles remain readable
  without shifting the next target.
- Back returns to tools; Escape/outside click closes through the existing menu
  observer. Pointer exit keeps an explicitly opened panel available. The input
  draft survives dismissal and defers restore/update restart until saved or
  cleared. Ordinary backups still capture saved tasks. Why: closing must not
  silently discard text or allow a restore to replace it.
- No task movement animation; Reduce Motion also disables panel-mode animation.
  White text at 76% or above is used for secondary text on the dark hover surface.
  Why: completion remains precise and text retains a readable contrast.

Validation uses temporary archives and synthetic offscreen fixtures at 310, 360
and 500pt. Native text-field Return dispatch was exercised in an invisible window,
without activating the app. The history-date fixture measures 9.67:1 against its
row background (RGB 211/41). Physical keyboard/VoiceOver, native tooltip timing and compositor glass
appearance require acceptance on the one installed application.
