# Exodia

Native macOS client (Swift + SwiftUI + AppKit, SwiftPM). BYOK first, with
optional local models; free, MIT. Two hotkeys: hold Space in an editable
field -> voice -> paste; Right Command tap (text) / hold (voice) -> local
OpenCode -> the user's selected OpenRouter model -> answer in the island. No account, no Exodia servers,
no telemetry. The user-facing name is Exodia (formerly Whytap); the module and most internal
identifiers are still `Sidekey`. The public source repository is
`https://github.com/AbsoluteMode/exodia`. Preserve legacy bundle IDs, Keychain
services and Application Support paths so existing settings and permissions
survive the rename. WHY: .project-docs/decisions/2026-10-17-exodia-name.md

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
            - Your key (BYOK): direct to the provider with the user's key
              from the Keychain (Streaming/BYOK/): OpenAI Realtime or a
              self-hosted OpenAI-compatible endpoint, Deepgram, Soniox,
              ElevenLabs
            - Local: FluidAudio Parakeet TDT v3 (Core ML), app-owned cache in
              Application Support, Apple Silicon only, offline after the
              one-time download (Streaming/Local/)
       Soniox Stop: drain all captured audio -> 200ms PCM silence -> explicit
       finalize + text EOF. A final <fin> acknowledgement completes the take;
       finished=true also completes it. The 10s watchdog remains the backstop.
       -> cleanup (PostProcessor, level = LLMIsolationLevel):
            OpenRouter with the user's key / custom OpenAI-compatible endpoint
            (Ollama, LM Studio, vLLM) / local MLX Qwen3 / none
            (raw transcript + Filler stripping). An unconfigured route
            degrades to the no-LLM output; the paste never fails on it.
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
            to batch recovery over the retained PCM with the local model
            (`LocalBatchTranscriber`, skipped when the Parakeet model is not
            downloaded; bounded by BatchRecoveryDeadline, 30s), then
            rung3 raw partial, then rung4 .deliveryFailed ("Couldn't
            deliver" + Retry). .deliveryFailed is escapable: a new take
            discards it. Empty batch = silence, not offline. WHY:
            docs/decisions/2026-07-26-empty-batch-is-silence-not-offline.md,
            docs/decisions/2026-06-24-deliveryfailed-escapable-and-retry-robust.md
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
  AgentDaemonWorkingDirectory uses neutral agent/ or sibling
  project-agents/<UUID>/ under Application Support/whytap. Each project has its
  own AGENTS.md, sessions.json and .opencode-runtime config/data/state/cache.
  AgentController adds selected project evidence to each turn and uses scoped
  resume IDs. Evidence is untrusted content, never executable instructions.
  WhytapCustomizationContext.promptInstructions exposes resolved local Monitor
  paths, dashboard/collector contracts and source-kit discovery to the runtime
  agent, so creating a dashboard does not require finding the source checkout.

Meeting Notes:
  Always-on detector (mic activity + CoreAudio system audio + FluidAudio
  Silero VAD; fires only when a recognised meeting app writes the mic)
       -> island nudge: Take notes / Skip (20s) -> MeetingRecorder (mic +
          system audio, 16 kHz PCM16; the system-audio tap exists only while
          recording, WHY: docs/decisions/2026-06-16-system-audio-tap-on-record-only.md)
       -> processing: fully local (mic track = "Me", system track diarised by
          FluidAudio -> "Speaker N", alignment by time, MLX summary with
          map-reduce for long transcripts; the three models load SERIALLY
          with evict() between stages) or BYOK processor (Soniox file API with speaker-attributed turns and durable job/transcript checkpoint;
          other providers use their adapters, then LLM with the user's keys). Neither configured = the meeting is
          marked failed with `LocalModelMessaging.meetingProcessorNotConfigured`
          and its audio stays staged; a `MeetingFinalizeManifest` re-dispatches
          it later with the language captured at Stop time.
       -> MeetingsStore (local SQLite) -> notes window (BlockNote in WKWebView)
  Manual start: Option M (configurable), the Record hover tile, or Settings ->
  Other; all converge in MeetingsCoordinator.toggleManualRecording(). With the
  Meeting Notes capability off, the manual start shows the nudge as an
  enable-prompt. Auto-end when the system mic is released for 3s (not before
  the 30s startup grace); an auto-ended recording waits 45 seconds as
  pendingReconnect and ANY detector re-fire shows "Notes | Reconnect | Skip";
  resuming is always the user's decision. WHY:
  docs/decisions/2026-07-29-reconnect-always-asks.md

Local LLM (Apple Silicon):
  MLX (`ml-explore/mlx-swift` + `-lm`), Qwen3-4B-Instruct-2507-4bit;
  diarisation FluidAudio Core ML. Gate = `LocalModelSupport.isAppleSilicon`
  (runtime sysctl `hw.optional.arm64`, not `#if arch`: the binary is
  universal). Weights download from Hugging Face into Application Support.
  Unified strings in `LocalModelMessaging` (not Apple Silicon / offline and
  not downloaded / not downloaded).
  Metallib: SwiftPM does not compile Metal shaders; `Resources/mlx.metallib`
  is built by `scripts/build-metallib.sh` and VERSION-LOCKED to the resolved
  mlx-swift revision (bump both together). It ships as a sealed resource in
  `Contents/Resources/` with a relative symlink from `Contents/MacOS/`; never
  put it directly into `Contents/MacOS/` and never sign it separately
  (breaks first-launch Gatekeeper on Sequoia). WHY:
  docs/decisions/2026-06-30-metallib-sealed-resource-sequoia-gatekeeper.md

Hover capsules and materials:
  IslandHoverPanelControl.swift renders a 139x64 foreground capsule with a left
  36 pt white icon disk/blue glyph and normal-case 12 pt title plus optional 11 pt
  current status inside. Bundled icon assets retain their own presentation.
  HoverToolPresentation resolves state purely from mode, languages and recording:
  Fast/Smart, input Auto/language, output Smart only/Off/language, and Recording/
  Not recording. Stateless navigation tools have no invented status.
  HoverLayoutStore.columns=3. Shared geometry uses 80 pt rows, 8 pt row/column gaps,
  12 pt horizontal and 8 pt vertical insets. Drawer width=457 pt
  (3*139+2*8+24); default six tools occupy two rows and a 267 pt host band.
  At most four rows are visible; 13+ selected tools scroll without truncating
  persistence. Settings stays last; first five positional hotkeys remain.
  Compact pill and music keep their existing 310 pt layout; detached hover panels
  and native hit zones use 457 pt. Hints overlay stable targets without moving them.
  Each card has one native .regular backdrop in an independent background shape
  on macOS 26+, with passive rims and foreground lenses, never child glassEffect.
  Explicit hover/press/magnetic feedback respects Reduce Motion. Older material
  fallback is unchanged. Do not show test windows over the user's work; use
  offscreen checks and state compositor limits. Earlier v3/v4 fixtures predate
  this capsule/width change. The 2.2.3 candidate passed 2,947 tests (8 skipped,
  0 failures) and 21 offscreen layout/text renders with no visible/key windows.
  Offscreen renders do not prove native glass, real pointer or Monitor-button
  behavior; production acceptance remains separate. WHY:
  .project-docs/decisions/2026-10-17-native-hover-glass.md

Monitor inside hover:
  Monitor registry kind is inlinePanel and HoverSlotRouter resolves
  .openPanel(.monitor). Capsule, catalog search and positional hotkeys all open
  MonitorHoverPanel in the same drawer, with contentHeight 344 pt: dashboard
  picker -> Server status or custom dashboard -> Back to picker -> Tools.
  The view starts MonitorStore when shown and stops it on disappearance;
  Refresh calls requestRefresh and reuses existing collectors/snapshot rendering.
  Hover launch and the legacy openMonitor callback both request inline .monitor
  with programmatic expansion; neither opens a window. The legacy window class
  is retained for compatibility only. Guide: docs/customization/dashboards.md.

Hover tool search and pointer routing:
  Search all tools searches the full catalog (titles, descriptions and aliases),
  including tools not pinned in Toolbox. Activation shares HoverSlotRouter and
  never changes the saved layout. Only clicking the field acquires keyboard
  focus; ordinary hover and active visual treatment leave the user's app focused.
  On macOS 26+, NSSearchField uses a custom cell drawInterior without the black
  bezel, keeping native text/search/cancel geometry; its field editor is clear.
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
  Community archives use our independent Sparkle Ed25519 signature and ad-hoc
  app code signing, without Apple Developer/notarization. Source dev builds
  (9999 / -dev) do not start the binary updater. WHY:
  .project-docs/decisions/2026-10-17-community-updates.md,
  docs/decisions/2026-06-17-update-download-on-action.md,
  docs/decisions/2026-07-08-update-download-spinner-and-post-relaunch-updated-indicator.md
```

Presentation: show Your key (BYOK) before Local in both Models segments and
user-facing setup instructions. Preserve saved processing routes; changing
presentation order does not switch where existing users send audio or text.
WHY: .project-docs/decisions/2026-09-10-byok-and-local-builds.md

First run: no sign-in and no onboarding wizard. Launch and reopen show the
island immediately. Configure provider keys and optional local models in
Settings -> Models, the agent in Settings -> Agents, and permissions in
Settings -> Permissions. A feature can request the permission it needs when
invoked. Drop with a local model selected but not downloaded opens
Settings -> Models. Settings opens on Models; screenshot protection is in
Other (default off). The former tour, resume state, preview target and
voice demos were removed. WHY:
.project-docs/decisions/2026-10-17-local-workspace.md

Project knowledge: Settings -> Projects registers a user-selected folder and
manual notes. ProjectKnowledgeStore keeps a local catalog and SQLite FTS5
index, with explicit reindexing and path/line citations. Hidden files,
symlinks, build directories and common credential filenames are excluded;
indexing is bounded to 5,000 files and 32 MB of text. It does not scan the
home directory automatically or use semantic embeddings. Retrieval requires
an explicitly selected project. Matching excerpts and notes become context
for that project's agent request and may go to its configured API provider.
This is a knowledge foundation, not live meeting-question detection.

Customization: any local coding harness can use the same source checkout.
Run `python3 scripts/customize.py discover --json` for commands, change
contracts and source entry points; `doctor --json` checks build prerequisites.
Build/run use the canonical dev bundle script; hover and dashboard scaffolds
are drafts. Guide: docs/customization/README.md. Update the capability map
when moving its source entry points. Do not publish private monitoring
configuration, project contents or credentials with the source.

Installation: SidekeyAppMain checks InstallationGuard before constructing the
app delegate. A read-only or AppTranslocation copy shows Finder installation
instructions and quits before permissions, provider discovery or updates.
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
  `CGEventTap` in `SpaceHoldMonitor`.
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
# Commit relevant build inputs before the build; retain the adjacent DMG manifest
FLAVOR=prod ./scripts/user-release.sh --build-only
# Publishing also needs the project's Sparkle signing key and GitHub access
FLAVOR=prod ./scripts/user-release.sh --upload-only
```

Exodia stays open source and uses ready-made community builds for normal installs
and updates. The default DMG/Sparkle pipeline builds/signs locally without Apple
Developer membership, Developer ID or notarization; publishing requires our
independent Sparkle Ed25519 signing key and GitHub access. Keep archive signature
verification and app integrity checks. The former Apple-signed mode remains
optional behind `EXODIA_LEGACY_SIGNED_RELEASE=1`. Do not disable Gatekeeper or
other OS protections. First downloads may require user approval and macOS
permissions can require regranting. WHY:
`.project-docs/decisions/2026-10-17-community-updates.md`.

Release provenance is required: commit and clean Sources, Resources, Package.swift,
Package.resolved, VERSION and scripts before building. Capture build-time HEAD;
seal archive SHA-256/size, version, build and flavor in `<DMG>.manifest.json`.
Upload-only requires the adjacent manifest. Reject missing/inconsistent
provenance, changed HEAD or archive bytes before signing-key access/uploads, and
target the release at the verified manifest's build commit. Rebuild after changing
HEAD; do not relabel an old archive. Candidate validation remains a release gate.

Source users still pull and rebuild locally for their own customizations. Dev
9999/-dev bundles opt out of packaged updates so a binary cannot overwrite their
modified app. Earlier Whytap installs can use a different feed and need a manual
first Exodia installation; changing the new GitHub feed cannot migrate that copy.

GitHub Actions is disabled to avoid hosted-runner costs; do not enable or dispatch
it. Run appropriate local build/tests and record the results in the PR. BYOK-first
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
   model downloads from Hugging Face, providers and monitoring sources the
   user configured (including their credential store), OpenCode's own provider
   traffic, its official GitHub release download, `google.com` opened in the
   browser, and the Sparkle feed on GitHub Releases.
   `Tests/SidekeyTests/CloudRemovalTests.swift` fails the build on any
   Whytap hostname or removed cloud symbol under `Sources/`.
2. **Keys and content never leave through logs.** BYOK keys live only in the
   Keychain (`BuildConfig.keychainService`). `os_log` never receives
   transcripts, prompts, replies or keys (`LocalPathLoggingInvariantTests`).
   Key contents read by the hotkey tap are never logged or persisted.
3. **Local models are Apple Silicon only, gated at runtime**
   (`LocalModelSupport.isAppleSilicon`); Intel users get BYOK / custom
   endpoints. There is no paid gate anywhere.
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
