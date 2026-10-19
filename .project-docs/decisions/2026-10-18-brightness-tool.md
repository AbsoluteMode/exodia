---
id: brightness-tool-2026-10-18
type: decision
title: Brightness is a catalog hover tool with a backlight slider, an Extra switch and battery time
summary: A short inline strip sets the island display's backlight, offers an EDR Extra switch that adds a fixed boost until the user switches it off, and shows the battery time left; optional Brightness keys show the strip instead of the macOS indicator. Saved and default layouts are unchanged.
status: confirmed
tags: [hover, brightness, edr, battery, display, settings]
canonical_for: [brightness-tool]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: On 2026-10-18 the user asked for a separate Brightness hover tool building on the earlier Vivid/XDR research, with a white slider continuing into a yellow extra-brightness zone, the expected runtime on battery and a plain strip opened from hover. The same day they replaced the yellow zone with a separate Extra switch.
    confirmed_at: 2026-10-18
  - type: user-confirmed
    reference: On 2026-10-19 the user reported the boost steady after the frame fix (the washed-out look they saw then came from Vivid running at the same time), then a dim moment on every ⌘Tab, even a quick tap without the switcher panel. They noted that Extra survived lowering the brightness through macOS but ended with Exodia's slider, and asked for Extra as a fixed addition to the brightness that ends only when switched off, reachable from Settings -> Toolbox as well as hover. They then asked for the brightness keys to show the hover strip instead of the macOS indicator, with two brightness-up presses at full brightness turning Extra on.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Brightness/ScreenBrightnessController.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Brightness/BrightnessBoostOverlay.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Brightness/BatteryRuntime.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Brightness/IslandBrightnessStrip.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Brightness/BrightnessKeys.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Brightness/BrightnessKeyEventTap.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Brightness/ToolboxDisplayPane.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandView.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Tests/SidekeyTests/Brightness/
    confirmed_at: 2026-10-19
  - type: trace
    reference: Read-only battery probe on the developer's MacBook (macOS 27.2, on battery), nine samples over four minutes.
    confirmed_at: 2026-10-18
  - type: trace
    reference: Final local runs. Before merging main, focused hover, search, Monitor and Brightness filter 283 tests, 0 failures, and full swift test 3,015 tests, 8 skipped, 0 failures (51.123 s). After merging main f3f9174, full swift test 2,892 tests, 5 skipped, 0 failures (49.711 s), then the four Brightness suites 53 tests, 0 failures, no warnings. customize.py build exit 0 with the dev bundle signature verified both times; fourteen offscreen strip PNGs (seven states at 310 and 330 points).
    confirmed_at: 2026-10-19
  - type: trace
    reference: Live dev-build check, 2026-10-19 (MacBook Pro XDR, macOS 27.2). The user saw the screen blink with Extra on. WindowServer's display headroom hint fell from 2.67 to 1 within 0.07 s of Exodia losing key focus (18:31.588 -> 18:31.655) and 0.77 s after a keepalive frame without a focus change (19:02.354 -> 19:03.128); it rose to 2.67 0.05 s after the strip became key (18:21.946 -> 18:21.995).
    confirmed_at: 2026-10-19
  - type: trace
    reference: After the frame, title and restore fixes. Focused hover, search and Brightness filter 118 tests, 0 failures; full swift test 2,931 tests, 5 skipped, 0 failures (51.322 s); no warnings in the Brightness files. After the two fixes from Argon's review, the three Brightness suites 47 tests and full swift test 2,933 tests, 5 skipped, 0 failures (52.461 s), no warnings in the Brightness files.
    confirmed_at: 2026-10-19
  - type: trace
    reference: WindowServer, SkyLight and MenuBarAgent logs over nine app switches with Extra on (13:36-13:39, 2026-10-19). Backlight and headroom stayed unchanged (headroom 2.67, limit 1600 nits) from 13:36:32 until the dev build quit at 13:39:17, with Vivid already closed. All switches stayed on one Space; seven were ⌘Tab, four of them with the Dock's switcher panel for 0.7-2 s and three without it.
    confirmed_at: 2026-10-19
  - type: trace
    reference: After the fixed boost, the app-switch frames, Settings and Brightness keys. BrightnessKeysTests 38 and BrightnessHoverToolTests 16 tests, 0 failures; full swift test 2,977 tests, 5 skipped, 0 failures (56.562 s), no warnings in the Brightness, IslandView, AppDelegate or Settings pane files; fifteen offscreen Settings pane PNGs.
    confirmed_at: 2026-10-19
  - type: trace
    reference: Independent read-only reviews of PR #30 on 2026-10-19. Codex found the boost lost with focus, the restore target lost after a failed write and the first transparent frame; Argon (Gemini) agreed on the cause and found the stale origin within the settle window and frames requested from sleeping displays. Claims were checked against the code and by failing tests.
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developer.apple.com/videos/play/wwdc2022/10114/ (Display EDR content with Core Image, Metal, and SwiftUI)
    confirmed_at: 2026-10-19
related: [../project.md, 2026-10-17-hover-tool-search.md, 2026-10-17-native-hover-glass.md]
---

# Brightness tool

## Context

The user asked for brightness control as its own hover tool, building on the
earlier Vivid/XDR research: a white slider, extra (XDR) brightness and the
expected runtime on battery, opened as a plain strip from hover. They then
replaced the yellow Extra continuation of the slider with a separate switch.
After the first live checks they asked for Extra as a fixed boost that only
the switch ends, for the switch in Settings as well, and for the Mac's
brightness keys to show the strip instead of the macOS indicator.
macOS has no public backlight API for Apple displays, and brightness above the
SDR maximum exists only as EDR headroom that apps fill with their own content.

## Decision

**Tool.** `HoverTool.brightness` is an `.inlinePanel` resolved to
`.openPanel(.brightness)`. It is offered from the Toolbox catalog and search
(brightness, display, яркость, vivid, xdr, battery, батарея);
`HoverLayoutStore.defaultSlots` and saved layouts are unchanged. Its capsule
title is Display and shows NN% or Extra, and no status for an unreadable display.

**Strip.** 68 points: Back, a white Control Center style capsule slider with the
sun at its start, the Extra switch and one status line (an orange notice, or
the battery). The band is 76 points, 126 with music. The mode takes keyboard
focus like Monitor, so the slider and switch receive clicks. Opened from a
lower tile, the band keeps the previous height as transparent hover space under
the top-aligned drawer until the pointer reaches the strip.

**Backlight.** `DisplayServicesGetBrightness` and `DisplayServicesSetBrightness`
are resolved with `dlopen` from the private DisplayServices framework, for the
island display chosen by `IslandScreenResolver`. An unreadable display gets a
disabled slider, a one-line explanation and no switch. Opening the strip only
reads. While it is visible the controller polls every 0.5 seconds; after a
write, readings from that display are ignored for 0.75 seconds, because the
panel can still report the earlier level, so key presses in a row step from
the written level. A pinned capsule reads the level once when hover opens.

**Extra.** Offered when `maximumPotentialExtendedDynamicRangeColorComponentValue`
exceeds 1.01. Turning it on never writes the backlight: it orders a
click-through panel at `CGShieldingWindowLevel` on all Spaces and over
full-screen apps. Its 1x1 `rgba16Float` extended-linear sRGB `CAMetalLayer`
wants EDR content and uses `compositingFilter = "multiply"`, so WindowServer
multiplies the desktop by the EDR white `min(2, potential headroom)` at
whatever level the backlight has. The panel becomes visible after the first
rendered frame and has `sharingType = .none`. A multiplier or frame change
draws at once; `BrightnessBoostFrameTimer` also presents a frame every 0.2
seconds while the overlay exists, with the strip open or closed, whenever its
window is visible (and until the first frame succeeds). On
`NSWorkspace.didActivateApplicationNotification` it presents a frame at once
and then 15 more at 1/60-second intervals; another switch during that burst
restarts its count. No frame is presented between `screensDidSleep` and
`screensDidWake`, `willSleep` and `didWake`, or `sessionDidResignActive` and
`sessionDidBecomeActive`, and each pause ends only with its own notification.

**Lifetime.** Extra is a fixed boost on top of the current backlight. It stays
on through the slider at any level, the Mac's brightness keys, automatic
brightness, idle dimming, closing the strip, display and system sleep and a
session switch, whose frames pause meanwhile. It ends when the user switches
it off in the strip or in Settings, and otherwise only on a serious or
critical thermal state (the cooling notice, which also blocks turning it on),
a display change, lost headroom or an unreadable display, an overlay failure
(the Extra notice) and app quit. Ending it leaves the backlight where it is.
Extra is never saved and never comes back by itself after relaunch. Each
notice fits one line of a 310-point island.

**Settings.** Settings -> Toolbox -> Display (`ToolboxDisplayPane`) is a card
with the Extra switch, when the island display offers it, and the Brightness
keys switch, without a slider. It reads the display when it appears and then
follows the controller's display notifications; it never polls. A display
without Extra shows one grey line instead of its row. While macOS refuses the
keys, their row's description reads "Needs Accessibility. Allow it in
Permissions.", and showing the pane retries the tap. Every state fits the
188-point area under the tool header.

**Brightness keys.** Off by default; the switch is in Settings -> Toolbox ->
Display and is saved. While it is on, a session event tap (head insert, not
listen-only) on its own thread receives only system-defined events and takes
the brightness key presses (aux control subtype 8, key types 2 and 3) from
macOS, so the system indicator does not appear. A press moves the island
display's backlight to the next sixteenth of the range, or sixty-fourth with
Option-Shift, at least a quarter step away. A brightness-up press at the
maximum followed by another within 1.5 seconds turns Extra on; the press that
reaches the maximum does not count, and repeats from holding the key neither
count nor cancel. A brightness-down press keeps Extra. Each press shows the
strip as a glance: it closes after 2 seconds instead of the 4 of a positional
hotkey and leaves keyboard focus with the user's app. A glance replaces the
tools or the strip itself; it never opens over another panel under the
pointer or a search being typed, which leave the level changed without it.
Under the pointer the strip opens as from its tile, with focus, and a pointer
that reaches a glance from below holds the drawer and takes focus. While a
meeting suggestion, a recording or the agent blocks expansion, the level
changes without the strip. The keys stay with macOS while hover widgets are
hidden, while the island display is not adjustable, and with Command,
Control, Option or Shift other than Option-Shift; Fn and Caps Lock do not
matter. Whether a press goes to Exodia or to macOS is decided on its first
event, and its repeats and release follow it. The tap is installed again with
the hotkeys (wake, an Accessibility change) and given up when macOS disables
it a fourth time in a row without an event, or at once without Accessibility.

**Battery.** IOKit power sources give the percentage, power state and macOS's
time to empty. AppleSmartBattery gives the remaining charge
(`AppleRawCurrentCapacity` x `Voltage`) and the load accumulators in
`PowerTelemetryData`. The monitor samples every 5 seconds while the strip is
visible. On battery macOS's estimate comes first; without it, the remaining
watt-hours over the smoothed per-update average load (EMA weight 0.5,
discarded after a 5-minute gap). On power the same calculation shows
"N h if unplugged", otherwise "On power" or "Charging". Times round to 5
minutes under an hour, then to 10.

Battery readings and brightness key events are never stored, logged or sent;
only the Brightness keys switch is saved. The strip and Extra need no
permission; Brightness keys need the Accessibility permission the hotkeys use.

## Why

- The separate switch is the user's correction: one explicit on/off instead of
  a slider zone whose meaning changes past the end.
- The fixed boost is the user's correction of 2026-10-19: Extra survived the
  Mac's own keys but ended with Exodia's slider. Without a level to restore,
  there is no restore that can fail and no write of a backlight level the user
  did not choose. Sleep and a session switch keep it for the same reason: only
  the switch ends it.
- Catalog-only follows the Toolbox contract: a new tool does not replace the
  user's selections or change the default layout.
- A multiply overlay needs no screen capture, Screen Recording permission,
  gamma tables or shaders, and closing the window removes the effect at once.
- 2.0 is about the sustained full-screen XDR range over the SDR maximum on
  MacBook Pro panels; WindowServer limits the result to the current headroom.
- A uniform multiplier needs no full-resolution half-float drawable.
- Without focus, WindowServer keeps a layer's EDR headroom only about 0.8
  seconds after its last frame. Redrawing on change plus a 2-second keepalive,
  and only while the strip was open, made the boost blink: the headroom hint
  fell to 1 when Exodia lost focus and between keepalive frames. Five frames a
  second, BrightIntosh's rate for the same overlay, fit three frames in that
  hold. Frames pause while the window is not visible, while the displays or
  the Mac sleep and during another user's session: a sleeping display does not
  consume them, and waiting for a drawable would block the main thread for up
  to a second. The notifications make the pause independent of when the
  occlusion state changes.
- The app-switch burst: through nine switches WindowServer kept the headroom
  and the backlight, yet the user saw a dim moment on every ⌘Tab, panel or
  not. The leading explanation is a composite at the switch without a recent
  overlay frame, so an activation gets one at once and a quarter second of
  60-hertz frames. It is not yet confirmed on the panel.
- Display replaces the Brightness capsule title, which wrapped to two lines in
  the 43-point text column of a 310-point island (the user's screenshot).
- Extra costs power and heat, so heat ends it and nothing turns it on without
  the user.
- Brightness keys are off by default because they take keys from macOS and
  need Accessibility.
- A press is decided on its first event so macOS never receives half of one.
- Combinations stay with macOS because they are its own shortcuts (Option
  opens Displays settings); Option-Shift is the Mac's fine step.
- A glance takes no keyboard focus so a key press while typing leaves the text
  field focused, and it does not replace a panel the user is using.
- The keys have no Help window row, `HotkeyHintView` or `HotkeyConfiguration`
  entry: they are the Mac's own keys, not an Exodia hotkey.
- The Settings pane has no description above its card so every state fits the
  Toolbox area without the window changing height.
- Polling only while the strip is visible keeps hover free of background work;
  with Extra on, the overlay's frames are the only background work.
- On battery the user compares with the system's own number; the accumulator
  estimate fills the gaps and is the only source on power.
- The settle is per display, so another display's reading stays current after
  a switch.
- The height hold keeps the drawer open: the strip is much shorter than the
  grid, and a pointer left on a lower tile would otherwise fall outside it.
- `powerplug.fill` is used because `powerplug.portrait.fill` needs macOS 15.

## What was tested

- `ScreenBrightnessControllerTests` (24) with fake devices: read-only opening,
  per-display settle, Extra adding the multiplier without a backlight write,
  switching it off leaving the backlight as it is, the slider and outside
  changes keeping it at any level, sleep and a session switch keeping it, a
  display change ending it and reading the new display at once, an overlay or
  render failure ending it with a notice, a late failure from a closed
  overlay, an unreadable display that is never written and has no switch, and
  thermal pressure blocking Extra and pausing only an active one. The six
  fixed-boost tests failed first against the earlier model, for example
  `["write 1 1.0", "overlay 1"]` instead of `["overlay 1"]`; six tests of the
  earlier restore model were removed with it.
- `BrightnessBoostFrameTimerTests` (13), written before the timer existed:
  frames arrive without calls from the strip, none while the overlay cannot
  present, while the displays or the Mac sleep or during another session, and
  again only after every pause has ended; none after stop or release; three
  frames fit in the measured 0.77-second hold. The display-sleep test failed
  first (the timer had no sleep state). The two app-switch tests failed first
  with 0 frames instead of 1. The pause and stop checks of the burst passed at
  once and were proved by mutation: without the pause check a switch while
  paused presented 1 frame instead of 0, and without stopping the burst a
  closed overlay received 4 frames.
- `BrightnessKeysTests` (38), written before the keys existed (the first run
  failed with 65 assertion failures): press and release parsing, other system
  keys left alone, Option-Shift and the other modifiers, sixteenth and fine
  steps to the next mark and at both ends, the two-press gesture (the press
  reaching the maximum, holding, other presses, the window), a press kept or
  left whole across interception changes, stray releases, the two keys apart,
  steps from the last written level or a level changed elsewhere, Extra on the
  second press, brightness down keeping it, no headroom, the setting (off by
  default, remembered, the tap kept on a second start, removed when off, keys
  left to macOS while hover is hidden or the display is not adjustable, a
  refused tap retried on start and only a refused one when Settings opens, a
  tap macOS stops, quit keeping the setting) and the glance (no focus, which
  panels it replaces, 2 seconds, the pointer holding it from below, which
  failed first). Seven mutations of the parsing, filter, handler and setting
  were each caught.
- `BatteryRuntimeTests` and `BatteryRuntimeMonitorTests`: estimate priority,
  accumulators, counter reset, stale gaps, clamps, rounding, symbols available on
  macOS 14 and no republishing of unchanged samples.
- `BrightnessHoverToolTests` (16): catalog-only registration, search aliases, a
  capsule title that fits one line at 310 points (it failed with Brightness),
  capsule status, band heights and the hold, key focus, slider mapping, every
  text at 310 points, the real strip in an unordered offscreen window at 310 and
  330 points in seven states, and polling only while it is shown. This test
  caught a false pass: with `sizingOptions = []` the hosting view reports a zero
  `fittingSize`, so the first height check measured nothing. It now compares the
  ideal height exactly (68 points, 44 without a status line). The Settings pane
  reads the display without polling, retries a refused tap when shown (failed
  first) and fits 188 points in five display states with each of three key
  states; with a description above the card and a separate orange line it
  measured 215.5 to 285.5 points and failed 11 assertions.
- Fourteen offscreen strip PNGs and fifteen Settings pane PNGs were inspected:
  text fits, nothing is truncated and the unavailable state has no switch.
- Battery probe: the first sample read 75 %, 62.6 Wh and a 20.8 W load, and
  macOS estimated 123 minutes ("75% · 2 h left"; pmset "2:03 remaining"). Over
  four minutes the accumulator estimate read 178, 161, 149, 153 and 162 minutes
  while macOS read 133, 149, 142, 162 and 172 minutes.
- Before merging main: the focused hover, search, Monitor and Brightness filter
  passed 283 tests with 0 failures; the full `swift test` executed 3,015 tests,
  8 skipped, 0 failures (51.123 s). After merging main f3f9174, which deleted
  25 test files since the base: 2,892 tests, 5 skipped, 0 failures (49.711 s),
  then the four Brightness suites passed 53 tests with 0 failures and no
  warnings. `customize.py build` built the dev bundle and its signature
  verified both times.
- Live dev build on 2026-10-19: the user reported blinking with Extra on.
  WindowServer and SkyLight logs tied every drop of the headroom hint to
  Exodia losing key focus or to a gap after the last frame (sources). After the
  fixes the focused filter passed 118 tests and the full `swift test` 2,931
  tests, 5 skipped, 0 failures (51.322 s); after Argon's two fixes, 2,933
  tests, 5 skipped, 0 failures (52.461 s). After the fixed boost, the
  app-switch frames, Settings and Brightness keys: 2,977 tests, 5 skipped, 0
  failures (56.562 s).

## Rejected alternatives

- A yellow Extra continuation of the slider: replaced by the user on 2026-10-18.
- Writing the backlight maximum when Extra turns on and restoring the earlier
  level when it ends (the first design), and ending Extra with the slider
  below the maximum: replaced by the user's fixed boost on 2026-10-19.
- Ending Extra on sleep or a session switch (the first design): only the
  switch ends it now; frames pause instead.
- Brightness in the default slots (an earlier draft): it would change new
  installations' layout; the catalog and search cover discovery.
- Gamma tables: they remap the existing output range instead of adding EDR
  headroom, and override the display's calibration while active.
- A full-resolution drawable: memory for a uniform value.
- One global settle after writes: it would hide another display's level.
- Resuming Extra after relaunch: the screen would brighten unasked.
- Our estimate ahead of macOS's on battery: noisier, and different from what the
  system shows.
- Drawing only while the strip is open: the boost blinked once Exodia lost focus.
- `preferredDynamicRange = .high` with `contentsHeadroom` (Codex's proposal):
  kept as the next hypothesis; it does not explain the drop 0.77 seconds after
  a frame without a focus change.
- Ending Extra on HDR suppression notifications: Extra would end whenever
  another app is in front, the opposite of the feature.
- Two frames a second (Argon's proposal): 0.5 seconds leaves 0.27 seconds under
  the measured 0.77-second hold, so one late main-thread tick would blink again.
- Skipping frames while a command buffer is in flight (Argon's proposal): GPU
  completion does not return the drawable, which the compositor keeps until it
  shows a newer frame, so it would not prevent the wait on a sleeping display.
- A listen-only tap or an `NSEvent` global monitor for the keys: neither can
  keep the macOS indicator from showing.
- Taking brightness key combinations with modifiers: they are macOS's own.
- A glance with keyboard focus, or over any open panel: a key press would take
  focus from typing or replace the panel in use.
- A separate orange line for refused keys in Settings: the pane no longer fit
  its 188 points.

## Verification boundary

Checked live on 2026-10-19 in the dev build, not the installed app: the first
Extra wrote the backlight maximum on the user's XDR panel and raised the
headroom hint to 2.67 (about 1600 nits), then blinked as described above.
After five frames a second the user reported the boost steady, apart from a
dim moment on every ⌘Tab. Not verified: the strip in a key window offscreen
(the switch renders grey because the window is not key), real pointer movement
and the height hold, the power and heat of Extra, whether ScreenCaptureKit
honours `sharingType = .none` on current macOS, and the on-power line with a
charger connected. macOS's own estimate moves from minute to minute.

Pending the user's live check: whether the app-switch burst removes the ⌘Tab
dip and what a quarter second of 60-hertz frames per switch costs; the fixed
boost at a low backlight and through sleep; Extra from Settings and a click on
either Settings switch (offscreen tests render the switches but do not click
them); and the Brightness keys: no macOS indicator, the glance, two presses at
the maximum, Option-Shift steps and the tap after wake. Also unchecked: whether
a transparent window reports itself visible before its first frame, a slider
drag that drifts below the strip (Argon expects the drawer to close mid-drag),
and the Display capsule on one line. Open with the user: whether sleep and a
session switch should keep Extra (it follows "ends only when switched off"),
and a Help window row for the keys. A live Extra check brightens the user's
screen and needs their consent.

2026-10-19 · [AbsoluteMode/exodia#30](https://github.com/AbsoluteMode/exodia/pull/30), branch `claude/brightness-tool-battery-587fda`.
