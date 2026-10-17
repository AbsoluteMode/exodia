# Add or change a hover tool

The user chooses any number of tools in **Settings, Toolbox**. Selected tools wrap
into rows of five. Settings stays last and cannot be removed. The editor always
shows an add target; the live hover grid shows the selected tools. The search
field above it searches the full catalog and launches a tool without pinning it.
Positions one
through five have configurable positional hotkeys. Tools in later positions are
accessible by pointer.

## Source map

All paths below start at `Sources/Sidekey/`.

| Responsibility | Source |
| --- | --- |
| Persisted identity, title, icon, description and kind | `Settings/HoverTool.swift` (`HoverToolRegistry` is in the same file) |
| User selection, reorder, insertion, removal and column count | `Settings/HoverLayoutStore.swift` |
| Tool to activation effect, inline panel requests | `DynamicIsland/HoverSlotRouter.swift` |
| Action closures and preview defaults | `DynamicIsland/IslandActions.swift` |
| Native controls, inline views and hover height | `DynamicIsland/IslandView.swift`, `IslandDropModeControl.swift` |
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
   contents. Do not fill the user's layout with defaults after a removal.
6. Preserve Settings as the final selected tool. A new tool belongs in the catalog;
   adding it does not authorize replacing the user's existing selections.

`scaffold-hover` creates an isolated view and checklist, not a registered feature.
The native app has no executable plugin loader. Integrate the requested source
change and rebuild it with the canonical development script.

## Checks

```bash
python3 scripts/customize.py test --filter 'HoverToolTests|HoverLayoutStoreTests|HoverSlotRouterTests|HoverHotkeyTests|IslandHoverPanelControlTests|IslandHoverToolSearchTests'
python3 scripts/customize.py run
```

Inspect one row and multiple rows, add/reorder/remove, Settings locking, relaunch
persistence and keyboard activation of the first five positions. Verify that a
click in the extra rows reaches the tool and that the panel collapses correctly.
Search for an unpinned Output Lang, verify keyboard and pointer activation,
clear with Escape, and check that clicking outside releases text focus. Ordinary
hover must not take focus from another app.
