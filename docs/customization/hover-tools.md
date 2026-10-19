# Add or change a hover tool

The user chooses any number of tools in **Settings, Toolbox**. Selected tools wrap
into rows of three compact capsules, 52 points high. The drawer has exactly the
same width as the compact island, using its actual notch-derived `compactWidth`.
Each cell width is `(panelWidth - 24 - 16) / 3`: 90 points for a 310-point island,
or about 90.67 for 312 points. Each shows an icon and title inside,
with a current status when the tool has state. Settings stays last and cannot
be removed. The editor always
shows an add target; the live hover grid shows the selected tools. The search
field above it searches the full catalog and launches a tool without pinning it.
At most four rows are visible in a 312-point grid viewport; the thirteenth
and later selections scroll without being removed. New-install defaults have six
tools, two rows and a 243-point host band; existing selections persist. Positions
one through five have
configurable positional hotkeys, independent of the column count.

## Source map

All paths below start at `Sources/Sidekey/`.

| Responsibility | Source |
| --- | --- |
| Persisted identity, title, icon, description and kind | `Settings/HoverTool.swift` (`HoverToolRegistry` is in the same file) |
| User selection, reorder, insertion, removal and column count | `Settings/HoverLayoutStore.swift` |
| Tool to activation effect, inline panel requests | `DynamicIsland/HoverSlotRouter.swift` |
| Action closures and preview defaults | `DynamicIsland/IslandActions.swift` |
| Capsule icon/title/status and explicit feedback | `DynamicIsland/IslandHoverPanelControl.swift`, `DynamicIsland/HoverToolPresentation.swift` |
| Inline views, shared three-column geometry and bounded scrolling | `DynamicIsland/IslandView.swift`, `DynamicIsland/IslandDropModeControl.swift` |
| Inline monitoring, picker and refresh lifecycle | `Monitor/MonitorHoverPanel.swift`, `Monitor/MonitorStore.swift` |
| Inline brightness strip, backlight, Extra overlay and battery time | `Brightness/IslandBrightnessStrip.swift`, `Brightness/ScreenBrightnessController.swift`, `Brightness/BrightnessBoostOverlay.swift`, `Brightness/BatteryRuntime.swift` |
| Measured pointer targets, viewport clipping and down/up ownership | `DynamicIsland/IslandHoverHitBridge.swift`, `DynamicIsland/IslandPanel.swift` |
| Catalog search, aliases, AppKit search field and keyboard commands | `DynamicIsland/IslandHoverToolSearch.swift` |
| Drag/drop catalog and selected layout | `Settings/ToolboxSettingsView.swift` |
| App services and hotkey dispatch | `AppDelegate.swift` (`onHoverSlotActivated`) |
| Positional hotkey labels and hints | `Settings/HotkeysSettingsView.swift`, `HelpWindowController.swift` |

## Tool contract

1. Give the tool a stable camelCase `HoverTool` case. `rawValue` is persisted in
   UserDefaults: do not rename or recycle an existing ID.
2. Add registry metadata. Choose `.action`, `.inlinePanel`, or `.navigate` to a
   Settings destination. Prefer an existing destination when it already fits.
3. Extend `HoverSlotRouter.effect(for:)`. For an action, add the matching
   `IslandActions` closure with a harmless preview default and a real production
   handler in `AppDelegate`. For an inline panel, also add its panel state and
   view in `IslandView`.
4. Update exhaustive switches in the live hover, Toolbox, search aliases and any
   navigation surfaces. Search results, tile clicks and positional hotkeys must
   cause the same effect. Search results must not mutate the saved layout.
5. Keep `HoverLayoutStore.columns` and the shared height calculation aligned. A
   new row must resize the AppKit panel and its hit region, not just the SwiftUI
   contents. `IslandHoverControlsLayout` centers fixed-height buttons; shortcut
   hints overlay the top edge without moving them. Keep native hit zones in sync
   with the drawer, compact pill and music at the actual `compactWidth`. Derive
   every capsule's width from that same value; never restore a fixed wide drawer.
   Preserve scroll content beyond four visible rows; do not fill or truncate saved layouts.
6. Preserve Settings as the final selected tool. A new tool belongs in the catalog;
   adding it does not authorize replacing the user's existing selections.
7. Use `HoverToolPresentation` for real mode/language/recording status, not a
   store read inside the control or an invented Enabled status for navigation.
   Monitor is `.inlinePanel` / `.openPanel(.monitor)` for every hover launcher;
   keep its dashboard picker and Back flow inside the drawer. Brightness is
   `.inlinePanel` / `.openPanel(.brightness)`, offered from the catalog and
   search only. Its strip is shorter than the tools, so the band keeps the
   previous height until the pointer reaches the strip.

`scaffold-hover` creates an isolated view and checklist, not a registered feature.
The native app has no executable plugin loader. Integrate the requested source
change and rebuild it with the canonical development script.

## Checks

```bash
python3 scripts/customize.py test --filter 'HoverToolTests|HoverLayoutStoreTests|HoverSlotRouterTests|HoverHotkeyTests|IslandHoverPanelControlTests|IslandHoverToolSearchTests|IslandHoverHitBridgeTests|HoverToolPresentationTests|IslandHoverPanelHitZoneTests|MonitorDashboardTests|BrightnessHoverToolTests|ScreenBrightnessControllerTests|BatteryRuntimeTests|BatteryRuntimeMonitorTests'
python3 scripts/customize.py build
```

Inspect one row and multiple rows, add/reorder/remove, Settings locking, relaunch
persistence and keyboard activation of the first five positions. Verify that
scrolling preserves and reaches tool 13+, all drawer/search/inline-panel native
hit regions match the compact island width, and music uses that same width.
Cover 310-point and 312-point examples, including fractional capsule widths;
History's 300-point reservation must fit its 280-point preview plus eight-point
gap with zero drawer overhang. Check pure status updates and Monitor picker -> dashboard -> Back in the same drawer.
Open Brightness from a lower row and check that the drawer stays open while the
pointer moves up to the strip. Fake devices cover the backlight and Extra in
tests; a live Extra check needs the user's consent, because it brightens their screen.
Use offscreen checks; do not open GUI test windows over the user's work.
Search for an unpinned Output Lang, verify keyboard and pointer activation,
clear with Escape, and check that clicking outside releases text focus. Ordinary
hover must not take focus from another app.

## Diagnose hover regressions

For a lost or misplaced click, inspect the measured target and viewport in
`IslandHoverHitBridge`, rather than adding a mouse-catching overlay. Down and up
must refer to the same unchanged control; dragging out, changing context or
closing the panel cancels activation. Internal search editing transitions must
not resign the key window before the result receives its owned mouse-up.

For flat glass or missing hover feedback, read the current
[native-glass and interaction decision](../../.project-docs/decisions/2026-10-17-native-hover-glass.md).
The native path uses one adaptive Regular backdrop on an independent background
shape per
card, with foreground capsules and passive highlights. It does
not wrap the foreground in glass or add nested native glass effects.
The search field and History use transparent foreground lenses, not black
surfaces; the native search cell keeps its geometry while omitting the bezel
paint. Active visual treatment leaves focus unchanged; explicit motion respects
Reduce Motion. Record macOS, backdrop and accessibility settings with the visual
evidence. Do not show test or fixture windows over the user's work; further
checks must remain offscreen. State that offscreen output does not verify the
external-desktop compositor, and do not change accessibility settings as an
incidental fix.
