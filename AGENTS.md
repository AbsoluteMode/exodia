# Exodia

Native macOS client (Swift + SwiftUI + AppKit, SwiftPM). BYOK only: the
user's provider keys or their own OpenAI-compatible endpoints, no on-device
models; free, MIT. Two hotkeys: hold Space in an editable
field -> voice -> paste; Right Command tap (text) / hold (voice) -> local
OpenCode -> the user's selected OpenRouter model -> answer in the island. No account, no Exodia servers,
no telemetry. The user-facing name is Exodia (formerly Whytap); the module and most internal
identifiers are still `Sidekey`. The public source repository is
`https://github.com/AbsoluteMode/exodia`. Preserve legacy bundle IDs, Keychain
services and Application Support paths so existing settings and permissions
survive the rename. WHY: .project-docs/decisions/2026-10-17-exodia-name.md

## Parallel development and the shared application

Read `.project-docs/processes/shared-app-development.md` for every feature task
and before integrating or updating the user's app. The user approved parallel
feature sessions with regular checked integration and one working application.

- Each feature uses its own branch/worktree. Workers build/test without
  launching, registering or installing their bundles. Do not run `dev-run.sh`
  or `customize.py build/run` from feature sessions; even build-only dev
  packaging on some branches stops other dev processes.
- Keep `/Applications/Exodia.app` (`com.rootwise.sidekey`) as the user's one
  working app, preserving signing identity, permissions and data. Source for
  shared updates is checked `origin/main`; first reconcile any fixes already
  installed from a feature branch. Do not replace them with older main code.
- Run exactly one Exodia instance across all channels: beta shares meetings,
  staging and clipboard history with production and competes for hotkeys.
  Production app/DMG packaging is reserved for the integrator under the lock.
- Any session may integrate ready work, but only one holds the shared
  `exodia-integration.lock` in `git rev-parse --git-common-dir`. Follow the
  runbook's owner/recovery protocol. Preserve all other sessions' WIP; use a
  clean integration worktree when the primary checkout is occupied.
- Review overlaps, validate the final combined candidate and merge through a
  PR with exact head/base checks. Routine checked integration/local refresh
  needs no repeated approval. Public publishing remains a separate action.
- Build a production candidate without interrupting the installed app. Verify
  its signature/identity against the installed app and require a newer build
  number without downgrading the display version. Keep the last working
  bundle. Recording, dictation, agent work, unsaved work or
  unknown activity defers replacement; never force-quit to install a feature.
- Maintain build/CURRENT_BUILD.md in the primary checkout with separate
  ready, merged, pending and verified-running states, source SHA, included
  features and 1–3 acceptance steps. Report what actually runs and what to
  check after promotion. A merge alone does not update the running app.
- Before integration/app actions, fetch and reread current `origin/main`'s
  guidance even in older worktrees. Resolve technical overlaps from accepted
  requirements; report incompatible product choices or unresolved risks.

WHY: .project-docs/decisions/2026-10-19-shared-working-app.md

## Architecture

```
Voice flow (Drop / dictation):
  User -> hold Space in an editable field + speech -> CGEventTap
       (SpaceHoldMonitor: hold ~300ms -> AX check of the focused field ->
        swallow + Backspace the leaked spaces; release = graceful finish:
        post-release tail until ~140ms of silence / max 450ms
        (StreamingFinishGate in StreamingAudioEngine) -> drain -> commit;
        Escape = cancel without tail)
       -> AutoPasteEngine.rememberTargetBeforeRecording (pid + name)
       -> realtime STT via TranscriptionSessionFactory
            (level = TranscriptionIsolationLevel, Settings -> Models):
            Your key (BYOK) only: direct to the provider with the user's key
            from the Keychain (Streaming/BYOK/): Soniox (default), Deepgram,
            ElevenLabs or a self-hosted endpoint speaking the OpenAI Realtime
            protocol. OpenAI itself is not offered; a legacy OpenAI choice
            resolves to Soniox. The self-hosted route has no default host: a
            missing or unparseable base URL fails (.missingBaseURL) before any
            socket opens, never reaching api.openai.com. WHY:
            .project-docs/decisions/2026-10-18-no-default-realtime-host.md
            No chosen level (never chosen on Apple Silicon, or the retired
            Local route) throws .notConfigured and opens Settings -> Models;
            a saved Local choice never switches to a provider on its own. WHY:
            .project-docs/decisions/2026-10-18-remove-local-models.md
       Soniox Stop: drain all captured audio -> 200ms PCM silence -> explicit
       finalize + text EOF. A final <fin> acknowledgement completes the take;
       finished=true also completes it. The 10s watchdog remains the backstop.
       -> cleanup (PostProcessor, level = LLMIsolationLevel):
            OpenRouter with the user's key / custom OpenAI-compatible endpoint
            (Ollama, LM Studio, vLLM). The mode is captured at take start:
            Fast bypasses the LLM; Smart requires processed text and never
            silently pastes raw speech after a cleanup error or empty result.
            Smart failures retain the transcript in memory and show Retry with
            the original mode and target; configuration errors open Models.
            Full, batch-recovered and partial transcripts use the same rule.
            A new take discards the old retry. The island observes persisted
            mode changes from every control. The cleanup provider mark appears
            only while processing; paste shows “pasting…” without a provider. WHY:
            .project-docs/decisions/2026-10-19-strict-drop-modes.md
       Smart uses the lowest supported OpenRouter reasoning effort (or off
       when optional), discovered from the cached model catalog, and asks
       OpenRouter to sort providers of the selected model by throughput. Meeting
       summaries and custom endpoints retain their own defaults. AX context
       has a 1.5s caller deadline. Diagnostics stay in local os_log and contain
       timings/counts/IDs only. WHY: docs/decisions/2026-09-07-smart-latency.md
       -> AutoPasteEngine.paste: pasteboard write -> Post Event preflight ->
            wait for modifiers released -> restore target focus -> settle ->
            CGEvent Cmd+V (4-event sequence)
       Resilient delivery: local audio is the truth. A degraded stream goes
            to batch recovery over the retained PCM through the
            `BatchTranscribing` seam (bounded by BatchRecoveryDeadline, 30s),
            then rung3 raw partial, then rung4 .deliveryFailed ("Couldn't
            deliver" + Retry). .deliveryFailed is escapable: a new take
            discards it. Empty batch = silence, not offline. Production binds
            `ProviderBatchTranscriber` (Streaming/BYOK/) for the batch rung,
            Retry, the recorder fallback and agent batch voice: the whole
            take goes to the provider selected in Settings -> Models with
            that provider's own Keychain key (Soniox file API, Deepgram
            pre-recorded, ElevenLabs speech-to-text, self-hosted
            /v1/audio/transcriptions over https), with the realtime
            request's language choices. No Your key level, no key for the
            selected provider, or a self-hosted URL without a host =
            unavailable, never another provider. Soniox polling stops after
            30s; its file, then its job, are deleted after every outcome.
            WHY:
            docs/decisions/2026-07-26-empty-batch-is-silence-not-offline.md,
            docs/decisions/2026-06-24-deliveryfailed-escapable-and-retry-robust.md,
            .project-docs/decisions/2026-10-18-provider-batch-transcription.md
       Transcript join (BYOKTranscriptJoin): Soniox tokens carry their own
            spaces = verbatim join; word-level providers = word-boundary join.
            WHY: docs/decisions/2026-07-22-hub-token-join-and-batch-recovery-deadline.md

Agent flow (OpenCode + OpenRouter):
  User -> Right Command tap (text) / hold (voice) -> RightCmdGestureMonitor
       -> voice: the same STT factory as Drop
       -> OpenCodeProvider -> opencode run --format json --model
          openrouter/<selected-model> --dir <local workspace>, prompt on stdin
       -> complete text/tool events rendered progressively in the island
  Settings -> Agents installs an app-managed OpenCode binary from its official
  GitHub release after SHA-256 digest verification, or locates an existing CLI.
  The user chooses an exact OpenRouter model ID or one from the live catalog,
  enters their key, then Save & connect checks the local version and free
  OpenRouter key endpoint. Connecting does not submit a model request.
  The key shares the existing OpenRouter Keychain store and enters only the
  child process environment, never a credential JSON file or argv. The runtime
  enables only OpenRouter, disables sharing/default plugins/automatic updates
  and excludes inherited provider credential/config environment variables.
  Actions are allowed by default so the agent can edit and run tests; the user
  can turn them off in Settings. This is an action policy, not a filesystem
  sandbox. No provider fallback or automatic model substitution.
  AgentDaemonWorkingDirectory uses agent/ under Application Support/whytap
  with AGENTS.md, sessions.json and .opencode-runtime config/data/state/cache.
  Projects, folder indexing and automatic project evidence are removed. Old
  project catalogs, indexes and project-agent workspaces remain unused on disk;
  never migrate their content or resume IDs into the neutral workspace. WHY:
  .project-docs/decisions/2026-10-19-remove-projects.md
  WhytapCustomizationContext.promptInstructions exposes resolved local Monitor
  paths, dashboard/collector contracts and source-kit discovery to the runtime
  agent, so creating a dashboard does not require finding the source checkout.

Meeting Notes:
  Always-on detector (mic activity + CoreAudio system audio + FluidAudio
  Silero VAD, the only remaining Core ML model, downloaded from Hugging Face
  on the first speech check; fires only when a recognised meeting app writes
  the mic)
       -> island nudge: Take notes / Skip (20s) -> MeetingRecorder (mic +
          system audio, 16 kHz PCM16; the system-audio tap exists only while
          recording, WHY: docs/decisions/2026-06-16-system-audio-tap-on-record-only.md)
       -> processing: BYOK processor only (Soniox file API with
          speaker-attributed turns and durable job/transcript checkpoint;
          other providers use their adapters, then the LLM route the user
          chose). Speaker labels come from the provider; there is no
          on-device diarizer. Without a chosen speech level and LLM route
          (including the retired Local route) the meeting is marked failed
          with `MeetingsCoordinator.processorNotConfiguredMessage` and its
          audio stays staged; a `MeetingFinalizeManifest` re-dispatches it
          later with the language captured at Stop time. A recording without
          speech is not a failure: a completed Soniox job without segments
          stores a "No speech detected" note without the LLM and releases the
          staged audio, so it is never retried. Model failures remain errors.
          WHY: .project-docs/decisions/2026-10-18-silent-meetings.md,
          .project-docs/decisions/2026-10-18-remove-local-models.md
       -> MeetingsStore (local SQLite) -> notes window (BlockNote in WKWebView)
  Delete: a finished meeting (ready or failed) has "Delete…" in its row
  context menu behind a confirmation whose default button is Cancel.
  MeetingsCoordinator.deleteMeeting removes the staged recording first (while
  its manifest exists, launch recovery would bring the meeting back), then the
  row and its note and transcript files; a meeting still processing is
  refused. The row's delete commits only after the transcript and then the
  note are gone, so a failed Delete leaves the meeting listed with its note.
  A note save that lands after Delete writes nothing (MeetingsStore.update
  checks the row first). Launch recovery frees the whole staged directory of
  a meeting that already has a note, and keeps the audio when the note is
  missing. Remote Soniox resources are not cleaned by Delete. WHY:
  .project-docs/decisions/2026-10-18-delete-meeting-and-staged-audio.md
  Manual start: Option M (configurable) or the Record hover tile; both
  converge in MeetingsCoordinator.toggleManualRecording(). With the
  Meeting Notes capability off, the manual start shows the nudge as an
  enable-prompt. Auto-end when the system mic is released for 3s (not before
  the 30s startup grace); an auto-ended recording waits 45 seconds as
  pendingReconnect and ANY detector re-fire shows "Notes | Reconnect | Skip";
  resuming is always the user's decision. WHY:
  docs/decisions/2026-07-29-reconnect-always-asks.md
  A BYOK key read that fails with errSecInDarkWake (no Keychain prompt
  possible: dark wake or the lid closing) defers the meeting instead of
  failing it: no failure event, the earlier failure reason is restored and
  the manifest stays for the next pass (startReady() after a full wake, or
  the next launch). WHY:
  .project-docs/decisions/2026-10-18-meeting-recovery-dark-wake.md

Hover capsules and materials:
  The 2026-10-17 user correction requires hover and the compact island to have
  exactly the same width, with three smaller capsules per row. Follow the actual
  notch-derived compactWidth (310/312 pt examples), not a fixed 457 pt drawer.
  IslandHoverPanelControl.swift defaults to a 90x52 foreground capsule with a
  30 pt white icon disk with 17 pt blue symbols, normal-case 11 pt title and optional 10 pt
  current status inside. The grid supplies each instance's exact width through
  IslandHoverControlsLayout.tileWidth(panelWidth:): (panelWidth - 24 - 16) / 3.
  User feedback on 2026-10-18 called the 24 pt disks and 12 pt symbols too small;
  larger icons retain the same capsule and text sizes.
  Historical 2.2.5 icon-refinement proof covers 101 focused tests and 18
  source-matched offscreen renders with no visible/key windows (layout/text only).
  Bundled icon assets retain their own presentation. HoverToolPresentation
  resolves state purely from mode, languages, recording and brightness:
  Fast/Smart, input Auto/language, output Smart only/Off/language,
  Recording/Not recording, and NN%/Extra (none for an unreadable display).
  Stateless navigation tools have no invented status.
  HoverLayoutStore.columns=3. Shared geometry uses 68 pt rows, a 76 pt row
  stride, 8 pt row/column gaps, 12 pt horizontal and 8 pt vertical insets.
  Default six tools occupy two rows and a 243 pt host band. At most four rows
  are visible (312 pt grid viewport); 13 tools retain 388 pt of scroll content.
  Settings stays last; persistence and the first five positional hotkeys remain.
  Settings Toolbox draws editable tools, a permanent Add target, then Settings,
  using stable tool/Add identities. Add occupies the actual insertion position.
  Drop targeting highlights without moving targets or saving. Native hosted
  destinations set animatesToDestination=false in prepare, before AppKit removes
  its preview and perform commits the current target identity. Settings has no
  registered drop types; cancel/invalid/stale sessions do not save. No timers or
  manual preview replacement. The 2.2.8/1460 candidate was not published after
  the user reported a duplicate cursor/inserted image. Grid changes
  ease over 0.18 s and highlights over 0.1 s; Reduce Motion disables both.
  The editor can be hosted independently of Case/Vocab/provider stores. WHY:
  `.project-docs/decisions/2026-10-18-toolbox-drag-feedback.md`.
  Drawer, compact pill, music, detached inline panels and native hit zones all
  use the actual compactWidth. Hints overlay stable targets without moving them.
  History needs no drawer overhang: its 300 pt left reservation still fits a
  280 pt preview and 8 pt gap without moving the island's right/top anchors.
  Each card has one native .regular backdrop in an independent background shape
  on macOS 26+, with passive rims and foreground lenses, never child glassEffect.
  Explicit hover/press/magnetic feedback respects Reduce Motion. Older material
  fallback is unchanged. Do not show test windows over the user's work; use
  offscreen checks and state compositor limits. Historical 2.2.4 compact
  candidate passed 69 focused tests and the full 2,947-test suite (8 skipped,
  0 failures, 45.315 seconds). Eighteen actual capsule/search-layout renders cover
  310/312 pt layouts with source-hash match and no visible/key windows.
  Dark text-audit backing is test-only. These checks do not prove native glass,
  real pointer, physical input/focus or live Monitor-button behavior; production
  acceptance remains separate. Historical 2.2.3 evidence (2,947 tests: 8 skipped,
  0 failures; 21 renders) covers the earlier 139x64/457 pt layout. WHY:
  .project-docs/decisions/2026-10-17-native-hover-glass.md

Monitor inside hover:
  Monitor registry kind is inlinePanel and HoverSlotRouter resolves
  .openPanel(.monitor). Capsule, catalog search and positional hotkeys all open
  MonitorHoverPanel in the same compact-width drawer: dashboard picker -> Server
  status or custom dashboard -> Back to picker -> Tools. The 2026-10-18 user
  clarification keeps the Monitor heading and centers it precisely, using equal
  88 pt navigation/refresh slots. Do not remove the heading or grow the drawer
  with dashboard count. IslandView .controls/.monitor share
  controlsHoverPanelHeight(toolCount:): six tools give a 243 pt host band/235 pt
  content; three tools give 167/159 pt. Music adds 50 pt to the host band for its
  strip and gap. The picker scrolls vertically in a bounded LazyVStack; long
  dashboard lists stay within the normal controls height. Keep user-facing
  dashboard choices here; setup instructions and local paths belong in the guide.
  Its compactPresentation uses vertical CPU/RAM/load/GPU metrics and one flexible
  column of custom widgets; the legacy window keeps its existing presentation.
  The view starts MonitorStore when shown and stops it on disappearance;
  Refresh calls requestRefresh and reuses existing collectors/snapshot rendering.
  Hover launch and the legacy openMonitor callback both request inline .monitor
  with programmatic expansion; neither opens a window. The legacy window class
  is retained for compatibility only. Historical 2.2.6 Monitor/search proof:
  2,949 tests, 8 skipped, 0 failures (45.711 s); search-focused 9/0 (3.901 s).
  Source-matched offscreen checks cover 16 Monitor fixtures/20 current PNGs and
  40 search PNGs with no visible/key windows. Synthetic no-op stores avoid real
  collectors/user data; native glass, real pointer/focus and installed-app
  acceptance remain separate. Guide: docs/customization/dashboards.md.

Brightness inside hover:
  Brightness is an inlinePanel tool offered only from the Toolbox catalog and
  search; its capsule title is Display, which fits one line of the narrowest
  capsule. HoverLayoutStore.defaultSlots and saved layouts are unchanged.
  HoverSlotRouter resolves .openPanel(.brightness) to IslandBrightnessStrip:
  Back, a white capsule backlight slider, an Extra switch and one status line
  (a notice, or the battery time left). The strip is 68 pt (76 pt band, 126 pt
  with music) and needsKeyboardFocus for its controls. Opened from a lower
  tile, the band keeps the previous height as transparent hover space under the
  top-aligned drawer until the pointer reaches the strip (onContinuousHover
  releases it), so the drawer does not close under the pointer.
  ScreenBrightnessController follows the island display (IslandScreenResolver)
  and reads/writes its backlight through private DisplayServices (dlopen); an
  unreadable display gets a disabled slider and no switch. Showing the strip
  only reads, polling every 0.5 s while it is visible; a pinned capsule
  refreshes NN%/Extra when hover opens. Extra exists only for potential EDR
  headroom > 1.01 and never writes the backlight: it orders a click-through
  shielding-level BrightnessBoostOverlay (1x1 rgba16Float extended-linear
  MTKView, multiply compositing, multiplier min(2, headroom), sharingType none)
  over whatever level the backlight has. BrightnessBoostFrameTimer presents a
  frame every 0.2 s while the overlay window is visible, strip open or not:
  without focus WindowServer keeps the boost only ~0.8 s after the last frame,
  so the former 2 s keepalive blinked. Each app activation adds a frame at once
  and 15 more at 1/60 s, because every ⌘Tab dimmed the boost (pending live
  check). Frames pause during display sleep, system sleep and another user's
  session, each until its own end notification. Extra is a fixed boost: the
  slider at any level, brightness keys, automatic brightness, idle dimming,
  closing the strip, sleep and a session switch keep it. Only its switch (strip
  or Settings) ends it, apart from serious thermal state, a display change or
  lost headroom, an overlay failure and quit; ending it leaves the backlight as
  it is. Extra is never persisted or resumed after relaunch.
  Settings -> Toolbox -> Display (ToolboxDisplayPane) holds the Extra and
  Brightness keys switches without a slider; it reads the display on appear,
  never polls and fits the 188 pt Toolbox area in every state. Brightness keys
  are off by default and saved. BrightnessKeyEventTap, a head-insert session
  tap for system-defined events on a SpaceHoldMonitor.TapThread, takes the
  brightness key presses from macOS, so its indicator does not show: sixteenth
  steps (Option-Shift: 64ths), two brightness-up presses at the maximum within
  1.5 s (timed when the tap sees them) turn Extra on, and each press opens the
  strip as a glance (2 s, no keyboard focus, never over another panel under
  the pointer or a focused search; a pointer reaching it holds the drawer).
  Other modifier combinations, hidden hover widgets and an unadjustable
  display leave the keys with macOS. A press stays with whoever got its first
  event, also across the hotkeys' rebuild; after a gap over 0.1 s or a tap
  macOS disabled, the presses in progress finish with macOS. The tap needs
  Accessibility, is reinstalled with the hotkeys and retried when the Settings
  pane appears. They are the Mac's keys, not an Exodia hotkey: no Help row.
  BatteryRuntimeMonitor reads IOKit
  power sources and AppleSmartBattery every 5 s while the strip is visible: on
  battery macOS's estimate wins, otherwise remaining Wh over the smoothed
  accumulator load; on power the line shows the time if unplugged. Battery
  readings and key events are never stored, logged or sent. WHY:
  .project-docs/decisions/2026-10-18-brightness-tool.md

Hover tool search and pointer routing:
  Search all tools searches the full catalog (titles, descriptions and aliases),
  including tools not pinned in Toolbox. Activation shares HoverSlotRouter and
  never changes the saved layout. Only clicking the field acquires keyboard
  focus; ordinary hover and active visual treatment leave the user's app focused.
  On macOS 26+, NSSearchField uses a custom cell drawInterior without the black
  bezel, keeping native text/search/cancel geometry; its field editor is clear.
  Its NSViewRepresentable.sizeThatFits explicitly returns the declared 30 pt
  height rather than AppKit's 24 pt intrinsic height. This keeps the native
  24 pt button rect inside the hosted field (y=4), avoiding a measured 1 pt
  overflow at the smaller height. The user-reported Monitor -> Back top slice
  was not reproduced offscreen. Live user feedback on 2026-10-18 confirmed it
  still occurs in the locally installed 2.2.6 candidate: the 30 pt fit is a
  partial correction, not a completed visual fix. Publication was stopped;
  GitHub v2.2.6 remains a draft with no publishedAt. Earlier tests/renders do not
  override this live feedback. The 2.2.7 candidate retains that 30 pt fit and the
  original searchButtonCell, setting only its isTransparent=true for the macOS 26
  glass cell. A separate NSImageView draws the public 13 pt SF loupe in a 14 pt
  square centered inside native searchButtonRect. Its hitTest returns nil and it
  is not an accessibility element. Native button identity, geometry, image,
  target/action, text/cancel and recents behavior are retained; older fallback
  and parent transitions are unchanged. Setup runs in init/layout without focus.
  Current proof: 10 focused tests/0 failures (3.933 s); final integrated full
  suite 2,953 tests, 8 skipped/0 failures (51.673 s), plus 60 source-matched
  native/transparent/explicit-glyph comparison PNGs with invisible/non-key
  windows. Exact clipping was not reproduced offscreen. On 2026-10-18 the user
  separately confirmed the loupe fully visible after installed 2.2.7 Monitor ->
  Tools. Public 2.2.7 build 1459 was published from sealed a35ca9d5778c65e9dbb861535178696c887293ee;
  independent public source/feed, both DMG hashes/signatures and read-only app
  checks passed. Do not claim a proved compositor cause.
  A translucent input lens/rim supplies the foreground surface without child
  native glass. History shares the drawer's Regular backdrop, uses translucent
  rows/hints and a separate preview backdrop. macOS 14/15 fallback is unchanged;
  Case/Vocab/Filler retain their existing transparent panels.
  Internal endEditing does not resign the key window between button down/up;
  captured activation or actual window resignation releases text-entry focus.
  Up/Down select, Return activates, Escape clears the query then releases focus.
  IslandHoverHitBridge measures target NSView frames at event time and clips
  results to their visible scroll viewport. NSWindow down/up must target the
  same unchanged control; drag-out, context/layout change, Escape and panel
  closure cancel activation. Drag/context/Escape cancellation keeps ownership
  of the eventual mouse-up; hiding the panel discards the sequence.
  Geometry reporters and decorative overlays never catch clicks themselves.
  The 42 pt search band and fixed overlaid shortcut hints participate in shared
  layout; hints do not shift buttons. Output language retains its Smart-mode
  requirement. WHY:
  .project-docs/decisions/2026-10-17-hover-tool-search.md,
  .project-docs/decisions/2026-10-17-native-hover-glass.md

Island display selection (multi-monitor):
  IslandScreenResolver.selectDescriptor is a pure function: user preference
  (Settings -> Other -> "Show island on") -> screen with a real notch ->
  primary display -> first. NSScreen.main is NEVER used (it is the key
  window's screen and moves with every click). All overlay panels position
  through currentDescriptor()/currentVisibleFrame() and follow
  selectionDidChangeNotification. WHY:
  docs/decisions/2026-07-07-island-display-selection-not-nsscreen-main.md

Now Playing:
  MediaRemoteNowPlayingSource runs the vendored adapter as a long-lived child
  (`perl run.pl <framework> stream --no-diff --micros`). The AppleScript
  source is the fallback. applicationWillTerminate calls
  NowPlayingCoordinator.shutdown(), which terminates that child synchronously
  (the async stop() would never run before exit()); the stream keeps running
  through sleep. For SIGKILL/crash the stream runs under a perl guard
  (parentWatchGuardScript) that ends it when the app's end of the guard's
  stdin closes; vendored run.pl stays untouched. WHY:
  .project-docs/decisions/2026-10-19-nowplaying-adapter-shutdown.md

Island idle-hide:
  ~20s without activity -> the compact pill fades to the bare notch (opacity
  0 + click-through; the window never moves or resizes). IslandIdleController
  with injectable clock; blockers keep it active (meeting recording, nudge,
  agent flow, drop, update pill, music, hover, held modifiers, programmatic
  expansion, "Updated" indicator). Wake = cursor in the pill rect + 24px, any
  of our hotkeys, or a blocker rising. Toggle "Auto-hide island" in
  Settings -> Other. WHY:
  docs/decisions/2026-07-09-island-idle-hide-settings-toggle.md

Update flow (download-on-action):
  SPUUpdater (hourly, automaticallyDownloadsUpdates = FALSE) + custom
  IslandUpdateUserDriver: no Sparkle windows, everything in the island.
  Scheduled check -> "Update" pill -> hover: Download | Skip -> download
  with a CALayer spinner (IslandUpdateSpinner; SwiftUI .repeatForever would
  freeze during main-thread stalls) -> requested install + relaunch while idle
  -> "Updated" indicator for 5s on the next launch (JustUpdatedIndicator,
  one-shot marker). A meeting recording, dictation or agent activity defers the
  app-initiated relaunch into Ready with Restart / Later; returning to idle alone
  never restarts it. Ready-stage Later replies .skip, cancelling the current
  installation without permanently skipping the version. The user approved
  applying a prepared, already downloaded update on ordinary application quit,
  unless Later cancelled it. Restored downloads use the same Ready actions and
  ordinary-quit policy. This does not guarantee behavior after force quit,
  crashes, process kills or power loss. A final Sparkle delegate guard rechecks
  activity before an app-initiated relaunch. Feed = GitHub Releases
  (`BuildConfig.appcastURL`).
  Community archives use our independent Sparkle Ed25519 signature, without
  Apple Developer/notarization. The app is signed with Exodia's self-signed
  community certificate when Resources/community-signing-certificate.pem is
  committed (stable designated requirement, so TCC grants survive updates),
  otherwise ad hoc. Source dev builds (9999 / -dev) do not start the binary
  updater. WHY:
  .project-docs/decisions/2026-10-17-community-updates.md,
  .project-docs/decisions/2026-10-19-community-signing-identity.md,
  docs/decisions/2026-06-17-update-download-on-action.md,
  docs/decisions/2026-07-08-update-download-spinner-and-post-relaunch-updated-indicator.md
```

Presentation: Settings -> Models offers only Your key (BYOK) for speech and
OpenRouter or a custom endpoint for text; Local was removed. Preserve saved
processing routes: never switch where existing users send audio or text. A
retired Local choice shows "not set up" banners until the user saves a
provider. WHY: .project-docs/decisions/2026-09-10-byok-and-local-builds.md,
.project-docs/decisions/2026-10-18-remove-local-models.md

First run: no sign-in and no onboarding wizard. Launch and reopen show the
island immediately. Configure provider keys and endpoints in
Settings -> Models, the agent in Settings -> Agents, and permissions in
Settings -> Permissions. A feature can request the permission it needs when
invoked. Drop without a chosen provider, key or endpoint opens
Settings -> Models. Settings opens on Models; screenshot protection is in
Other (default off). The former tour, resume state, preview target and
voice demos were removed. WHY:
.project-docs/decisions/2026-10-17-local-workspace.md

Notify: agent-configured local scripts emit JSON lines with title, body, event
ID, optional link, color, logo and duration. NotifyScriptSupervisor reads private
sources/<id>.json manifests, supervises child process groups only during the app
lifetime, restarts with bounded backoff and stops on disable, removal, sleep or
quit. No backend or built-in provider connectors are restored. The original
IslandNotificationPill / nonactivating panel sits left of the island, using the
selected screen and screenshot-protection preference. Hover pauses dismissal.
LocalNotificationHub persists up to 500 events, deduplicates scoped IDs and keeps
presentation in history; unreadable history is never silently overwritten. Notify
opens through hover search, Toolbox and existing positional hotkeys without
changing saved layouts. Settings -> Notifications lists connected sources with
their name, logo, runtime status and individual persistent enable switches.
Disabling stops the source and keeps its setup/history for re-enabling.
Agents get a resolved setup-guide path on every turn.
Guide: docs/customization/notifications.md. WHY:
.project-docs/decisions/2026-10-19-script-notifications.md

Planner: catalog/search actions To-do and Calendar open one native planner window
without changing saved layouts. PlannerStore atomically saves private local tasks
and Exodia events; unreadable archives block writes. CalendarConnections combines
selected EventKit calendars with direct Google Calendar, Microsoft Graph (including
Teams links) and Zoom Calendar Service connections. Remote events are read-only;
visible-range recurrence is provider-expanded, refresh runs only while the calendar
view is visible, and matching UID/occurrence bounds collapse duplicate sources.
OAuth uses browser S256 PKCE/state, a numeric loopback listener (Microsoft redirects
to localhost), and Keychain credentials with durable refresh-token rotation. No
shared OAuth registrations ship yet; live accounts require provider setup and
separate acceptance. Tests use fake providers and temporary stores. Guide:
docs/planner.md. WHY: .project-docs/decisions/2026-10-19-planner.md

Customization: any local coding harness can use the same source checkout.
Run `python3 scripts/customize.py discover --json` for commands, change
contracts and source entry points; `doctor --json` checks build prerequisites.
Build/run use the canonical dev bundle script; hover and dashboard scaffolds
are drafts. Guide: docs/customization/README.md. Update the capability map
when moving its source entry points. Do not publish private monitoring
configuration, project contents or credentials with the source.

Clipboard history retains the newest 50 local entries across launch, quit and
sleep/wake. Do not reintroduce automatic lifecycle wipes. New copies evict only
the oldest excess rows and their image sidecars; the current History feed shows
20 clipboard entries in a scrollable five-row viewport (Agent/Drop keep 10),
without deleting other retained rows. Startup seeds only the current
pasteboard change counter; dictation write/restore suppression remains. Before
replacing a running older binary with the old quit purge, preserve local
clipboard data privately and restore only clipboard rows/assets after quit.
WHY: .project-docs/decisions/2026-10-18-clipboard-retention.md

Installation: SidekeyAppMain checks InstallationGuard before constructing the
app delegate. A read-only or AppTranslocation copy shows Finder installation
instructions and quits before permissions, provider discovery or updates.
ApplicationInstanceCoordinator then acquires one common prod/beta/worktree lease
before constructing AppDelegate. A second copy offers to activate the owner and
quits without starting permissions, providers or hotkeys. Legacy binaries launched
later cannot honor the lease. Settings shows actual channel/version/build/path/revision.
WHY: .project-docs/decisions/2026-10-19-one-running-copy.md
`--installation-check` loads the packaged executable and verifies resources
without starting the app runtime. User guide: `docs/install.md`. Policy:
`.project-docs/decisions/2026-09-10-public-installation.md`.

Targets: library `Sidekey` (all app code) + thin executable `SidekeyApp`
(product `Sidekey`, `SidekeyAppMain.run()`) and `SidekeyTests`. Flavors: `prod` (default) and `beta` (`-DBETA`: separate
bundle id, keychain service and feed), see `Sources/Sidekey/BuildConfig.swift`.

## Permissions

- **Accessibility** gates `NSEvent.addGlobalMonitorForEvents`
  (`RightCmdGestureMonitor`; `EscapeCloseEventMonitor` is a passive bare-Esc
  close for the visible agent answer, WHY:
  docs/decisions/2026-07-02-escape-close-passive-monitor.md), the AX check
  of the focused field (`PasteTargetValidator`) and, empirically, the active
  `CGEventTap` in `SpaceHoldMonitor` and the optional Brightness keys tap
  (`BrightnessKeyEventTap`).
- **Post Event** gates `CGEvent.post` for the synthetic Cmd+V and Backspace
  (`CGPreflightPostEventAccess` / `CGRequestPostEventAccess`, a separate TCC
  bucket from Accessibility since 10.15; Tahoe shows both in one panel).
- **Input Monitoring** is only a lazy fallback: requested once if the tap
  could not be created while Accessibility is granted. Tap/toggle Drop uses
  Carbon `RegisterEventHotKey`, modifier Drop uses `ModifierOnlyHotkeyMonitor`;
  neither needs it. The tap reads all key events but handles only the trigger
  key and Escape; key contents are never logged or persisted.
- **System Audio Recording** (TCC `AudioCapture`) gates the CoreAudio process
  tap used for the other side of a meeting. Requires
  `NSAudioCaptureUsageDescription` (contract: `PackagingRebrandTests`);
  without the grant the tap silently yields zeros, so `SystemAudioVADProbe`
  rebuilds it at every recording start.
- **Microphone** for Drop, agent voice and meetings.

Drop reconciles failed installations and permission changes on activation,
reopen, Settings Refresh/Retry and a bounded quiet polling session. Carbon tap
shortcuts remain registered without AX so invocation can show permission repair.
Permission checks guard Start only; Stop is always available. Rebuilding active
capture monitors waits until capture ends. Background polling never asks for a grant.

## Commands

```bash
# Source build: existing local Sidekey Dev identity, or ad-hoc fallback.
# No Apple Developer account. macOS may require permissions again after rebuilding.
# Use the packaged app, not `swift run`, for permissions and resources.
./scripts/dev-run.sh --run

# Tests
swift test

# Harness-neutral change discovery and environment check
python3 scripts/customize.py discover --json
python3 scripts/customize.py doctor --json

# Explicit ad-hoc local build if no local certificate is desired
SIDEKEY_DEV_CODE_SIGN_IDENTITY=- ./scripts/dev-run.sh --run

# Community binary: local universal build, no Apple Developer
FLAVOR=prod ./scripts/user-release.sh --preflight-only
# Commit relevant build inputs before the build; retain the adjacent DMG manifest.
# Doppler supplies the community certificate's private key.
doppler run --project sidekey --config dev -- env FLAVOR=prod ./scripts/user-release.sh --build-only
# Publishing also needs the project's Sparkle signing key and GitHub access
FLAVOR=prod ./scripts/user-release.sh --upload-only
```

Exodia stays open source and uses ready-made community builds for normal installs
and updates. The default DMG/Sparkle pipeline builds/signs locally without Apple
Developer membership, Developer ID or notarization; publishing requires our
independent Sparkle Ed25519 signing key and GitHub access. Keep archive signature
verification and app integrity checks. The former Apple-signed mode remains
optional behind `EXODIA_LEGACY_SIGNED_RELEASE=1`. Do not disable Gatekeeper or
other OS protections. First downloads may require user approval. The community
certificate is public; its private key lives only in Doppler
(`EXODIA_COMMUNITY_SIGNING_KEY`, `sidekey/dev`) and is never committed or
printed. Never replace the certificate except for a leaked key: its SHA-1 is in
every build's designated requirement, so a new one makes every install regrant
macOS permissions. WHY:
`.project-docs/decisions/2026-10-17-community-updates.md`,
`.project-docs/decisions/2026-10-19-community-signing-identity.md`.

Release provenance is required: commit and clean Sources, Resources, Package.swift,
Package.resolved, VERSION and scripts before building. Capture build-time HEAD;
seal archive SHA-256/size, version, build, flavor and code-signing identity in
`<DMG>.manifest.json`.
Upload-only requires the adjacent manifest. Reject missing/inconsistent
provenance, changed HEAD or archive bytes before signing-key access/uploads, and
target the release at the verified manifest's build commit. Rebuild after changing
HEAD; do not relabel an old archive. Candidate validation remains a release gate.

Source users still pull and rebuild locally for their own customizations. Dev
9999/-dev bundles opt out of packaged updates so a binary cannot overwrite their
modified app. Earlier Whytap installs can use a different feed and need a manual
first Exodia installation; changing the new GitHub feed cannot migrate that copy.

GitHub Actions is disabled to avoid hosted-runner costs; do not enable or dispatch
it. Run appropriate local build/tests and record the results in the PR. BYOK
presentation and local validation remain required:
`.project-docs/decisions/2026-09-10-byok-and-local-builds.md`.

Details and the fork checklist: `docs/build-and-release.md`.

## Documentation

Everything lives in the repository: `CLAUDE.md` (architecture, commands,
invariants), `README.md` (user-facing), `docs/SPEC.md` (product spec),
`docs/hotkey.md`, `docs/privacy.md`, `docs/build-and-release.md`,
`docs/customization/` (coding harness workflow and capability contracts),
`docs/decisions/` (why), `docs/specs/` and `docs/plans/` (history).

After a change, update the matching place: architecture / components /
hotkey behaviour -> this file (+ `docs/hotkey.md` and a Help window row for
hotkeys); release flow -> `docs/build-and-release.md`; reasoning that is not
visible in the code -> a dated decision under `docs/decisions/` plus a
`// WHY:` anchor next to the code; product spec -> `docs/SPEC.md`. Mark the
PR with `[docs: na]` or `[docs: <path>]`.

## Hotkeys

New hotkeys follow `docs/hotkey.md`: `HotkeyHintView` is the only entry
point (`KeycapView` is internal), labels are capitalised, keycaps stand side
by side without `+`, modifiers are glyphs from `HotkeyGlyph`, and every
hotkey gets a row in the Help window (`HelpWindowController`). All hints
derive from `HotkeyConfiguration` (single source of truth for every surface).

## Invariants

1. **No Exodia-owned services.** The app never contacts an Exodia backend,
   has no account and sends no telemetry. Network traffic is limited to
   the meeting detector's Silero VAD download from Hugging Face, providers
   and monitoring sources the user configured (including their credential store),
   notification sources accessed by user-configured local scripts, calendar providers
   explicitly connected by the user (Google, Microsoft and Zoom), OpenCode's own provider
   traffic, its official GitHub release download, `google.com` opened in the
   browser, and the Sparkle feed on GitHub Releases.
   `Tests/SidekeyTests/CloudRemovalTests.swift` fails the build on any
   Whytap hostname or removed cloud symbol under `Sources/`.
2. **Keys and content never leave through logs.** BYOK keys live only in the
   Keychain (`BuildConfig.keychainService`). `os_log` never receives
   transcripts, prompts, replies or keys (`LocalPathLoggingInvariantTests`).
   Key contents read by the hotkey tap or the Brightness keys tap are never
   logged or persisted.
3. **No on-device models and no silent route change.** Speech, cleanup and
   meeting processing run only on providers or endpoints the user chose. A
   stored retired `local` level, or no stored level on Apple Silicon (where
   Local was the default), reads as not configured even when a key is stored;
   Intel keeps its Your key default (`SelfKeyPreferences`,
   `RetiredLocalRouteTests`). FluidAudio stays only for the meeting detector's
   Silero VAD; launch removes the retired models' weights under
   Application Support/Sidekey once per flavor and never touches FluidAudio's
   cache (`LegacyLocalModelCleanup`, WHY:
   .project-docs/decisions/2026-10-18-legacy-model-cleanup.md). There is no
   paid gate anywhere.
4. **Sparkle never shows a window.** Scheduled checks only show the island
   pill; nothing downloads before the user clicks. Requested downloads may
   install and relaunch while idle. Active meeting recording, dictation or
   agent work defers app-initiated relaunch; becoming idle alone does not restart
   it. Ready-stage "Later" cancels the current installation via .skip. A prepared
   download may apply on ordinary user-initiated app quit unless cancelled.
   Do not promise installation after arbitrary process termination. No manual
   "Check for Updates" menu or status bar item.
5. **Drop is remappable but hold Space by default.** Record a combo or bare
   Space in Settings -> Hotkeys (Raycast-style release-to-commit recorder).
   Space is hold-only; combos support hold or toggle; hold Drop goes through
   the generalised `SpaceHoldMonitor` (swallows the typed character, Escape
   cancels), tap/toggle Drop through Carbon, modifier Drop through
   `ModifierOnlyHotkeyMonitor`. One physical key = one action, except the
   right modifiers' tap/hold split (Right Command = agent text / voice).
   Hover buttons 1 to 5 have positional hotkeys Option 1 to Option 5 bound to
   `HoverLayoutStore.slots`.
