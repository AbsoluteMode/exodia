---
id: brightness-tool-2026-10-18
type: decision
title: Brightness is a catalog hover tool with a backlight slider, an Extra switch and battery time
summary: A short inline strip sets the island display's backlight, offers an EDR Extra switch that always returns the earlier level, and shows the battery time left; saved and default layouts are unchanged.
status: confirmed
tags: [hover, brightness, edr, battery, display]
canonical_for: [brightness-tool]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: On 2026-10-18 the user asked for a separate Brightness hover tool building on the earlier Vivid/XDR research, with a white slider continuing into a yellow extra-brightness zone, the expected runtime on battery and a plain strip opened from hover. The same day they replaced the yellow zone with a separate Extra switch.
    confirmed_at: 2026-10-18
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
    reference: Tests/SidekeyTests/Brightness/
    confirmed_at: 2026-10-19
  - type: trace
    reference: Read-only battery probe on the developer's MacBook (macOS 27.2, on battery), nine samples over four minutes.
    confirmed_at: 2026-10-18
  - type: trace
    reference: Final local runs. Before merging main, focused hover, search, Monitor and Brightness filter 283 tests, 0 failures, and full swift test 3,015 tests, 8 skipped, 0 failures (51.123 s). After merging main f3f9174, full swift test 2,892 tests, 5 skipped, 0 failures (49.711 s), then the four Brightness suites 53 tests, 0 failures, no warnings. customize.py build exit 0 with the dev bundle signature verified both times; fourteen offscreen strip PNGs (seven states at 310 and 330 points).
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
macOS has no public backlight API for Apple displays, and brightness above the
SDR maximum exists only as EDR headroom that apps fill with their own content.

## Decision

**Tool.** `HoverTool.brightness` is an `.inlinePanel` resolved to
`.openPanel(.brightness)`. It is offered from the Toolbox catalog and search
(brightness, яркость, vivid, xdr, battery, батарея);
`HoverLayoutStore.defaultSlots` and saved layouts are unchanged. Its capsule
shows NN% or Extra, and no status for an unreadable display.

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
write, readings from that display are ignored for 0.75 seconds. A pinned
capsule reads the level once when hover opens.

**Extra.** Offered when `maximumPotentialExtendedDynamicRangeColorComponentValue`
exceeds 1.01. Turning it on remembers the current level, writes the backlight
maximum, then orders a click-through panel at `CGShieldingWindowLevel` on all
Spaces and over full-screen apps. Its 1x1 `rgba16Float` extended-linear sRGB
`CAMetalLayer` wants EDR content and uses `compositingFilter = "multiply"`, so
WindowServer multiplies the desktop by the EDR white `min(2, potential
headroom)`. The panel becomes visible after the first rendered frame, redraws
only on change (plus a 2-second keepalive while refreshed and visible) and has
`sharingType = .none`.

**Lifetime.** Extra stays on after the strip closes and through outside
backlight changes (brightness keys, automatic brightness, idle dimming).
Moving the slider below 0.99 ends Extra at the new level; at the maximum it
stays on. Switching it off, a display change or lost headroom, sleep, session
resign, a serious or critical thermal state while Extra is on, an overlay
failure and app quit restore the level from before Extra. It is never saved and
never comes back by itself after wake or relaunch. Each notice fits one line
of a 310-point island.

**Battery.** IOKit power sources give the percentage, power state and macOS's
time to empty. AppleSmartBattery gives the remaining charge
(`AppleRawCurrentCapacity` x `Voltage`) and the load accumulators in
`PowerTelemetryData`. The monitor samples every 5 seconds while the strip is
visible. On battery macOS's estimate comes first; without it, the remaining
watt-hours over the smoothed per-update average load (EMA weight 0.5,
discarded after a 5-minute gap). On power the same calculation shows
"N h if unplugged", otherwise "On power" or "Charging". Times round to 5
minutes under an hour, then to 10.

Nothing is stored, logged or sent, and no permission is requested.

## Why

- The separate switch is the user's correction: one explicit on/off instead of
  a slider zone whose meaning changes past the end.
- Catalog-only follows the Toolbox contract: a new tool does not replace the
  user's selections or change the default layout.
- Starting Extra from the hardware maximum gives the brightest result and a
  clean level to restore.
- A multiply overlay needs no screen capture, Screen Recording permission,
  gamma tables or shaders, and closing the window removes the effect at once.
- 2.0 is about the sustained full-screen XDR range over the SDR maximum on
  MacBook Pro panels; WindowServer limits the result to the current headroom.
- A uniform multiplier needs no full-resolution half-float drawable.
- Extra costs power and heat, so every exit path restores the earlier level and
  nothing turns it back on without the user.
- Polling only while the strip is visible keeps hover free of background work.
- On battery the user compares with the system's own number; the accumulator
  estimate fills the gaps and is the only source on power.
- The settle is per display, so another display's reading stays current after
  a switch.
- The height hold keeps the drawer open: the strip is much shorter than the
  grid, and a pointer left on a lower tile would otherwise fall outside it.
- `powerplug.fill` is used because `powerplug.portrait.fill` needs macOS 15.

## What was tested

- `ScreenBrightnessControllerTests` with fake devices: read-only opening,
  per-display settle, the slider ending Extra, every restore path, a late
  failure from a closed overlay, an unreadable display that is never written and
  has no switch, and thermal pressure pausing only an active Extra.
- `BatteryRuntimeTests` and `BatteryRuntimeMonitorTests`: estimate priority,
  accumulators, counter reset, stale gaps, clamps, rounding, symbols available on
  macOS 14 and no republishing of unchanged samples.
- `BrightnessHoverToolTests`: catalog-only registration, search aliases,
  capsule status, band heights and the hold, key focus, slider mapping, every
  text at 310 points, the real strip in an unordered offscreen window at 310 and
  330 points in seven states, and polling only while it is shown. This test
  caught a false pass: with `sizingOptions = []` the hosting view reports a zero
  `fittingSize`, so the first height check measured nothing. It now compares the
  ideal height exactly (68 points, 44 without a status line).
- Fourteen offscreen PNGs were inspected: text fits and the unavailable state
  has no switch.
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

## Rejected alternatives

- A yellow Extra continuation of the slider: replaced by the user on 2026-10-18.
- Brightness in the default slots (an earlier draft): it would change new
  installations' layout; the catalog and search cover discovery.
- Gamma tables: they remap the existing output range instead of adding EDR
  headroom, and override the display's calibration while active.
- A full-resolution drawable: memory for a uniform value.
- One global settle after writes: it would hide another display's level.
- Resuming Extra after wake or relaunch: the screen would brighten unasked.
- Our estimate ahead of macOS's on battery: noisier, and different from what the
  system shows.

## Verification boundary

Not verified in the installed app: the strip in a key window (offscreen the
switch renders grey because the window is not key), real pointer movement and
the height hold, DisplayServices on the user's displays, and Extra on a real XDR
panel (brightness, power, heat, flicker). A live Extra check brightens the
user's screen and needs their consent. Also unverified: whether ScreenCaptureKit
honours `sharingType = .none` on current macOS, whether an unchanged overlay
keeps its multiplier with the strip closed (no keepalive then), and the
on-power line with a charger connected. macOS's own estimate moves from minute
to minute.

2026-10-19 · [AbsoluteMode/exodia#30](https://github.com/AbsoluteMode/exodia/pull/30), branch `claude/brightness-tool-battery-587fda`.
