# Interface decisions

## Settings appearance and switches

### Purpose and attention

Settings is a working surface for configuring providers, shortcuts and optional
features. The user first identifies the selected section, then reads each setting
and its current value, then changes that value without losing context.

### Direction and layout

- Use iOS inset groups within the existing macOS sidebar window. Groups describe
  related settings; individual rows do not get separate cards.
- Keep the current tabs and navigation. A small colored SF Symbol tile makes
  sections recognizable without changing their names or order.
- Use 14 pt group corners, 14 pt row insets, 9 pt vertical row padding and inset
  hairlines. Long descriptions wrap instead of shrinking the control.
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
