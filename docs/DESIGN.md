# Interface decisions

## Screenshot toolbar and capture reliability — 2026-10-21

The user comes to annotate a screenshot, discover the available tools, then
copy or download the result. First see the crop and every tool on the main bar.
Then change the selected tool's settings in an adjacent accessory and finish
with the visible **Copy & exit ↩** action or Enter.

- Expose Arrow, Shape, Pen, Text, Blur, Numbered steps, Share, Undo, Redo,
  Download, Copy & exit and Cancel. Remove More and the Select/crop control;
  keep the initial area drag. Clicking the active tool again stops drawing
  and restores direct selection/annotation adjustment without another button.
  Highlighter, Spotlight, Copy text, Pin above
  windows and Output size are removed, including their hidden commands and
  shortcuts. Why: the user chose a smaller annotation-focused tool set after
  reviewing every action; full pixel resolution remains automatic.
- Blur uses text alone; Download uses its downward arrow alone with a tooltip.
  Why: the user explicitly removed Blur’s icon and Download’s label.
- Keep color, width, shape, blur mode and label input in `ScreenshotToolSettings`,
  a separate native child panel. It follows the main bar without moving its
  targets when tools change; the label field uses a second accessory row.
  Why: the user explicitly replaced the previous inline-settings requirement.
- Preserve semantic AppKit typography, popover material and the accented finish
  action. All buttons highlight their full area on hover/press; native focus
  rings and control behavior remain. Accessory controls gain a hover outline;
  disabled controls suppress it. Borderless buttons draw semantic foregrounds
  without inline-cell dimming; native offscreen Blur text contrast measures
  9.02:1 light and 6.73:1 dark. Why: interactivity and text must stay readable.
- Wrap main-bar controls onto more rows at the width where they stop fitting,
  retaining order, full hit areas and every command. Why: exposing more tools
  must not hide Copy or clip controls on smaller displays.
- Enter and the copy button both copy the selected area and exit. The button
  names the outcome and shows ↩. No passive instruction strip remains; errors,
  processing and download results still appear when relevant. There is no
  full-display Enter/double-click mode. Why: the user wants area capture only.
- Cmd-Z / Shift-Cmd-Z undo/redo edits from both panels;
  a focused text field keeps native text undo. Tab/Shift-Tab traverse enabled
  controls in both panels. Unknown editor keys terminate locally instead of
  bubbling back into the forwarding window. Why: outcomes and shortcuts
  must be discoverable and match macOS editing behavior.
- Capture the visible Hover before any focus/search/hover cleanup or island
  wake. Hold its current open/closed mouse latch until pixels are frozen;
  include Whytap's visible windows in the capture. Why: the user expects the
  same visible-state freeze as Apple's region screenshot.
- Repeated Screenshot activation preserves the current capture. Unchanged
  screen-parameter notifications do not cancel it; actual display layout or
  Space changes still discard stale pixels. Sanitized lifecycle logs record
  reasons only. A 10-second capture deadline releases activity and permits retry
  even if ScreenCaptureKit does not return; it ends before editing starts.
  Why: repeated hotkey events must not toggle the editor off or leave it stuck.
- Request filter content points multiplied by ScreenCaptureKit's pixel scale
  with best capture resolution. Why: the affected Retina display reports
  1728×1117 through the legacy display functions but has 3456×2234 source
  pixels; exporting lossless PNG cannot recover detail already lost at capture.
  PNG also records its original point scale, avoiding a double-sized Retina paste.
- Keep both bars below a display's top safe-area inset. Why: full-display crops
  must leave controls reachable on Macs with a notch.
- Draw the primary accent fill independently of window activation, choosing
  black/white text for the stronger contrast. Why: the floating toolbar is
  usually not the key window, but Copy & exit must remain the leading action.

The later 21 October tool reduction also supersedes the initially expanded
21 October catalog. The earlier single-row/More/inline-settings decisions below are historical and
superseded by this user request. No new animation is introduced; reduced motion
uses the same immediate layout. Offscreen fixtures and generated pixels provide
local verification; actual hotkey delivery and capture remain single-installed-app
acceptance after the designated builder promotes the reviewed source.

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

## Provider key tiles — 2026-10-21

Tiles, form actions and picker rows show full-target hover and pressed feedback,
with distinct keyboard focus. Disabled controls are dimmed and ignore hover.
Feedback is local to API & Models; shared MacButton behavior stays unchanged.
Dark pressed overlays are capped at 8% to preserve small blue/white text contrast.

The person comes to connect a provider. First they see every available provider,
including OpenAI and Anthropic, then open its square to enter and check a key.
The chosen direction is the user's tile-to-inline-form request.

- Use square provider buttons in a responsive 2/3/4-column grid, with a 12 pt
  gap and 12 pt corners. Each tile is an independent provider connection, so
  its boundary has a purpose. Show the brand, provider name, speech/language
  purpose and key status even before a key exists. No decorative statistics.
- Clicking a tile expands a full-width form immediately below that tile's row.
  One form is open at a time; a thin accent outline marks it. Native keyboard
  focus has an outline too. Cancel, Escape or repeating the tile closes it;
  closing returns focus to that tile. Input receives focus on expansion.
- Keep the shared system typography and adaptive Settings colors: 13 pt title,
  11.5 pt explanation and 11 pt tile status. Hover never changes geometry.
  Expansion is immediate, including Reduce Motion. At narrow widths the grid
  reduces columns and the form retains the full row width.
- Check & save validates before persisting. Checking disables competing actions
  and shows progress; a failed/unreachable check keeps the form and old key.
  A successful check clears the typed value and shows the recorded provider
  result. Existing keys are never read back into the field. Removal keeps the
  existing confirmation and lists affected features. Custom endpoints retain
  their name, URL and optional-key fields.
- OpenAI and Anthropic are ordinary LLM providers for all text modes. Adding a
  key never assigns routes silently; model selection retains its own synthetic
  check. Why: the user rejected limiting API setup by individual features.

Native offscreen fixtures cover collapsed tiles and OpenAI, saved OpenRouter and
custom-server forms at 600/900 pt in both appearances. Shared token contrast on
tile surfaces is 17.01:1/14.58:1 for primary text (light/dark), 6.62:1/7.98:1
for secondary text and at least 5.59:1 for key-entry actions; selected-state
status text retains at least 5.98:1. Physical keyboard focus,
VoiceOver, actual key entry and live provider responses remain installed-app
acceptance; all automated transport checks use synthetic keys and stub servers.

## Searchable model selection — 2026-10-20

The user comes to choose a model without scrolling a long catalog. First they
see a focused search field, then matching model IDs under their provider.
The closed control retains the shared 30 pt popup label and existing widths.

- Open a 440 pt native popover with a fixed search band, 300 pt scrolling list
  and a fixed result count. Why: searching and browsing need no maintenance
  commands; the user removed Refresh models and Other model ID on 2026-10-21.
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
- Empty results offer Clear search; absent providers offer Add API key. Opening
  the picker automatically refreshes stale/failed catalogs, keeping the query
  and cached models. Successful catalogs are cached for one day; requests are
  single-flight per account. Search/arrow
  movement alone never selects or checks a model. An explicit pick uses the
  existing verification and route-preservation path.

Offscreen native fixtures cover the 440 pt picker in both appearances, filtered,
empty, absent-provider, stale-catalog and long/disabled-row states. Search and
native editing-command tests cover matching, stable ordering, account identity,
keyboard bounds and IME Return. These checks do not prove physical focus,
popover dismissal or VoiceOver on the installed app; those remain acceptance.
The interpretation that a family plus size is the useful search input follows
the user's example; typo correction and model aliases are outside this change.

## API & Models costs — 2026-10-20

The user chose four tabs in one surface: API keys, Models, Costs, API hints.
Costs first shows the nearby period, then used features with one Price column;
USD and ElevenLabs credit values retain explicit units, including both lines
when a feature used both. Model details appear on the feature. Why: compare
feature expenses without a permanent model-level grid or scattered period control.

- One existing bgCard surface, 14 pt corners, shared underlined tabs and quiet
  separators. No extra metric cards, chart, entrance or number animation.
- Period choices are Today, Last 7 days, This month and inclusive Custom dates.
  Each entry into Costs starts at This month. Local-calendar date labels stay
  beside the table header. Invalid dates, loading,
  empty history and a recoverable storage error have explicit states.
- System typography: 15 pt heading, 13 pt feature/value rows, 11.5 pt secondary
  labels. Aligned numeric columns use monospaced digits; colors reuse adaptive
  MacSettingsTheme tokens. Approximation and incomplete totals use text marks,
  so meaning does not rely on color.
- From/To controls share the period menu's 30 pt geometry, neutral fill and
  typography. They open a native calendar, closing on a changed date or Done/
  Return/Escape. Why: the user rejected mismatched black date fields and their
  persistent blue text selection. The control retains a keyboard focus outline.
- Hover opens model details; click pins, keyboard focus opens, Escape closes.
  Row fill follows actual pointer hover, so an open popover does not leave a
  selected-looking row after the pointer moves away.
  A short delayed dismissal permits pointer transfer into the native popover.
  The model list scrolls at 320 pt while its heading and explanation stay visible.
  Rows retain their geometry during disclosure; no new motion needs reduction.
- Historical feature/provider/model snapshots drive expenses. Unknown price is
  Unavailable, never free; ≈ denotes a calculated estimate and + excluded unknown
  costs. The permanent bottom explanation is removed at the user's request;
  help and model details explain these marks. ElevenLabs credits are never
  combined with dollars or inferred from a plan.

Offscreen native fixtures cover all four tabs at 600/900 pt, both appearances,
long model histories, custom dates, empty/error states and synthetic temporary-store
usage. Calculated text contrast on the card is 17.01:1 / 6.62:1 for primary/
secondary text in light appearance and 12.49:1 / 6.84:1 in dark appearance; the
selected-tab underline uses the primary text color. Physical pointer
transfer, keyboard/VoiceOver and live provider billing remain shared-app
acceptance. Tracking starts with this update; earlier history is not inferred.

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
Keep the existing permission group, MacRow and MacButton: this is one
more permission in the same workflow. A persistent explanation names
screenshots and tells them to finish current work before a macOS-requested reopen.

Only clicking Allow requests access; a denial
opens the system privacy pane. Returning to the app and Refresh reread access
without prompting. A missing grant never blocks launch or Drop. Existing native
button focus, keyboard activation, semantic colors and scroll behavior apply;
there is no new hover-only action or animation.

### Permission row status — 2026-10-20

The user requested one quiet indicator instead of dot chips and differently
labelled buttons. All three permissions use the same trailing slot:

- Granted: a 22 pt green `checkmark.circle.fill`, with no button or status chip.
  The icon exposes the permission name and Allowed to accessibility.
- Missing, not requested or denied: one Allow button, with the permission name
  in its accessibility label. Existing request handlers still choose the native
  permission prompt or the appropriate System Settings pane.
- The 60 × 26 pt slot keeps row height and text wrapping stable when access
  changes. The adaptive success color retains contrast in both appearances.
  No motion or hover-only information is added.

Offscreen native fixtures cover all granted, all missing and mixed access in
light/dark at 739 and 1059 pt content widths (the existing 960 and 1280 pt
Settings shells). Real TCC prompts, keyboard focus, VoiceOver and post-promotion
refresh remain installed-app acceptance. This presentation assumes the circled
checkmark is recognizable without a visible Allowed label.


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
| Search | Finds project and key names/descriptions, including empty projects and General. A project match shows all its keys; a key match shows just matching keys under its project. + Key stays available in project results. Return cannot create a key; name/value fields open separately after + Key. Empty results say Nothing found. |
| Connected icons | Open the selected registration directly. Connect stays visible beside the horizontally scrolling strip, including when empty. Codex/OpenAI uses blue, Claude/Anthropic orange, Cursor a white halo. Hover/focus change color and glow without changing geometry; keyboard focus has an outline. Reduce Motion removes the short opacity/color transition. |
| Client picker | Discovers installed OpenCode and Cursor only after Connect. Shows bundled brand marks, loading, no installed clients or already-connected states. Selecting a client opens a draft; nothing is registered until Connect on the rights screen. The arbitrary program picker is removed. |
| Rights | Default Accept asks before use; Bypass allows use without prompts. All projects explicitly includes future projects; Selected shows checkboxes and denies unchecked projects at the broker. Existing per-project overrides remain visible/editable. An empty saved scope closes access; a new connection needs at least one project or All. |
| Save | One transaction stores mode and scope; registration, widening access and enabling Bypass require Touch ID. Pending authentication disables edits and Back. Failure preserves the draft and explains recovery; connector errors remain visible after registration, with Retry setup reusing the same registration and rights. |
| Back / disconnect | Back discards unsaved rights. Disconnect revokes access before editing client config. Existing island outside-click and Escape dismissal still apply. |
| Approval | The request shows the command, app, project and key names. A native editable field changes temporary Bypass to 1–240 minutes without arrows; the separate temporary Bypass button and physical A use that value. The bottom row contains Deny/Allow only. Default 15 is restored for the next request. Grants are scoped to app/project and disappear at expiry, policy change or restart. |

Display metadata and project sections are rebuilt when the vault changes and
reused for renders. Search only filters/ranks metadata; values never enter its
index. The list is lazy so closed projects and offscreen rows do not create a
full hierarchy on every keystroke. Touch ID remains the opening gate.

Validation uses offscreen native fixtures, synthetic names and values, and fake
authentication. The installed application is reserved for acceptance through the
shared builder. These fixtures do not prove live keyboard focus or glass
contrast on every desktop; those remain runtime acceptance checks. The user's
reported lag may have been concurrent build load, not a confirmed app fault.


### Case search correction — 2026-10-20

A newly created empty project must be findable before it has keys. The user's
report corrects the earlier key-only interpretation: search is separate from
creation and includes projects too. Project matches reuse cached full sections;
key-only matches remain filtered. Search results expose + Key so the found
project can be used without clearing the query manually. Adding explicitly
expands that project before leaving search; existing cached metadata and
lazy rendering remain.


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
  A successful Return scrolls the new row into view, including in a long list.
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
  without shifting the next target. Native keyboard navigation to buttons follows
  the macOS Keyboard Navigation / Full Keyboard Access preference.
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


### Case Connect polish — 2026-10-21

The person comes to connect an installed agent. First they see OpenCode and/or
Cursor with their logos. Clicking one opens its access mode and project scope;
only Connect commits the draft after authentication. The user chose this flow.

- Offer OpenCode then Cursor, only when their existing locators find them and
  they are not registered. Do not offer a program chooser, Claude Code or Codex
  for a new connection. Keep all saved legacy registrations and their policy
  editors. Why: limit new setup to the two requested integrations without
  silently revoking existing rights.
- Bundle the official OpenCode mark and Cursor 2D cube as square transparent PDF
  templates, reused by the picker, policy header and connected strip. Why: the
  same agent should remain recognizable throughout setup, even in fixtures or
  after its app is removed. Sources: [OpenCode](https://opencode.ai/brand) and
  [Cursor](https://cursor.com/brand); SVG sources live beside their PDFs.
- Use 44 pt logo/name/disclosure rows, 22 pt marks, 10 pt corners, system 12 pt
  medium labels and the existing white-on-dark island palette. Hover changes
  the fill; keyboard focus adds an outline without moving the row. Native
  buttons expose the agent name and setup action. No new animation is added.
- Put Accept/Спрашивать and Bypass/Без запроса inside the mode choices, with an
  outline for selection and amber Bypass. Keep the shared-terminal consequence
  visible inside this group when Bypass applies. Why: the decision and its
  consequence should read together, without detached explanatory lines.
- Put all/selected project controls and their summary/checklist in a separate
  group. All explicitly includes current and new projects; unchecked projects
  remain denied. Existing project overrides get their own group. Why: scope
  must stay clear without a loose footer between unrelated controls.
- The primary Connect/Save button contains a Touch ID glyph. Native help and its
  accessibility hint explain which changes require authentication. Why: this
  explanation belongs to the commit action; normal mode/scope navigation does
  not request authentication. Errors and retry remain visible above the editor.
- Loading and both empty states are contained surfaces. With no installation,
  explain to install OpenCode or Cursor and reopen Connect; with saved supported
  registrations, point to their icons for editing rights. No client config,
  secret, route or vault migration changes are part of this polish.

Validation uses synthetic native offscreen fixtures at 310/390 pt and the
320 pt viewport, fake authentication, isolated connector files and the four
installed/absent client combinations. Calculated contrast on the synthetic
0.08-gray backdrop: group headings 10.56:1, selected/unselected mode text
10.15:1/9.58:1, picker labels 13.19:1, selected-mode border 4.35:1 and primary
button text 4.52:1. These do not establish contrast on every live backdrop.
Physical focus/VoiceOver, real Cursor
reconnection and live glass contrast remain shared-app acceptance after the
builder promotes the reviewed source. Grouping and logo recognition follow the
user's chosen direction; they have not been tested with other people.


Case control feedback follow-up — 2026-10-21: every custom/plain access control,
including Back, retry, mode, scope, project rows, disconnect and Save/Connect,
uses a shared full-target hover overlay, stronger pressed fill and keyboard-focus
outline. Disabled controls are dimmed and ignore hover/pressed/focus highlights.
Why: the user requires visible evidence of interactivity, beyond a button shape
or tooltip. Picker rows use the same feedback family. Offscreen state fixtures
cover normal/hover/pressed/focus/disabled at 310 pt; physical focus remains
shared-app acceptance. No authorization or registration behavior changes.

## Case approval controls — 2026-10-21

The person reviews a key-use request, then declines, allows once or grants
short temporary access. First they see the agent, project/key names and command.
The user chose a separate temporary Bypass button beside its numeric duration,
with only Deny and Allow in the final row. Keep the native black island card.

- Keep the 310/312 pt width and system type roles (12.5 pt header, 11.5 pt keys
  and buttons, 11 pt monospaced command). The command stays one line; native
  hover help and accessibility expose the full original string including line
  breaks. Why: the compact summary must remain inspectable before approval.
- Temporary Bypass is an actual capsule button with the existing physical A
  hint. The duration is a 34×24 pt native text field followed by мин, without
  arrows. Default 15 and supported 1–240 stay unchanged. Why: direct typing
  replaces repeated stepper clicks and removes the third competing bottom action.
- Invalid/empty drafts remain editable, show warning text color and disable the
  temporary action. They never change the grant duration; blur/Return restores
  the last valid number. Escape restores the pre-edit number and does not deny
  the key request. Return only finishes editing. Why: a partially typed duration
  must neither grant access nor silently authorize a different displayed number.
- The nonactivating panel does not take keyboard focus when it appears. An
  explicit field click or keyboard/AX first responder enables native editing.
  Approval hotkeys are suspended before the first typed character; clicks on
  the other actions still work after the existing quiet period. Finish editing,
  timeout, hide or replacement by a queued prompt releases the old field editor
  and key status. Why: numeric entry must not trigger Y/N/A/Escape or trap later
  typing in a panel that no longer contains the original field.
- Buttons visibly highlight their full capsule on hover, change fill while
  pressed and show a keyboard-focus outline. Disabled/unarmed buttons dim and
  suppress active hover/pressed feedback. The number field shows hover and focus
  borders. No geometry shifts or new motion are added; the existing arming fade
  respects Reduce Motion. Why: every interactive target must show feedback.
- Tool ergonomics: names-only `case_list_keys(query:)` matches all query words
  across authorized key name, description and project name, ignoring case and
  diacritics. Instructions show the existing `case run --only KEY` route for a
  known key; ambiguity retains explicit project choice. Why: agents can find a
  needed key directly without fetching all projects or changing value delivery.

Native offscreen fixtures cover short/long/queued/no-timed/unarmed cards at
310/312 pt. Focused controller/native-field tests cover keyboard first responder,
editing during arming, invalid text, Return/Escape, timeout and queued replacement
without ordering a panel front. Synthetic MCP tests confirm metadata-only search;
broker authorization and secret delivery remain unchanged. Physical pointer,
VoiceOver, native tooltip timing, text selection/IME and real Touch ID remain
shared-app acceptance after promotion. A real authorized key-presence check on the
previous installed build returned only a static presence confirmation; it does
not validate this new UI. No secret value was printed or sent over the network.
