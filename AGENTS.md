# Whytap

Native macOS client (Swift + SwiftUI + AppKit, SwiftPM). BYOK only: the
user's provider keys or their own OpenAI-compatible endpoints, no on-device
models; free, MIT. Two hotkeys: hold Space in an editable
field -> voice -> paste; Right Command tap (text) / hold (voice) -> local
OpenCode -> the user's selected OpenRouter model -> answer in the island. No account, no Whytap servers,
no telemetry. The user-facing name is Whytap (briefly named Exodia); the module and most internal
identifiers are still `Sidekey`. The public source repository is
`https://github.com/AbsoluteMode/whytap`. Preserve legacy bundle IDs, Keychain
services and Application Support paths so existing settings and permissions
survive the rename. Keep the existing community certificate, EXODIA_* release
variables, build metadata keys and backup formats/destinations as compatibility
contracts. WHY: .project-docs/decisions/2026-10-19-whytap-name.md

## Parallel development and the shared application

Read `.project-docs/processes/shared-app-development.md` for every feature task
and before integrating or updating the user's app. The user approved parallel
feature sessions with regular checked integration and one working application.

- Each feature uses its own branch/worktree. Workers build/test without
  launching, registering or installing their bundles. Do not run `dev-run.sh`
  or `customize.py build/run` from feature sessions; even build-only dev
  packaging on some branches stops other dev processes.
- Keep `/Applications/Whytap.app` (`com.rootwise.sidekey`) as the user's one
  working app, preserving signing identity, permissions and data. Source for
  shared updates is checked `origin/main`; first reconcile any fixes already
  installed from a feature branch. Do not replace them with older main code.
- Run exactly one Whytap instance across all channels: beta shares meetings,
  staging and clipboard history with production and competes for hotkeys.
  Production app/DMG packaging is reserved for the integrator under the lock.
- Finished feature agents automatically submit their reviewed PR/exact head,
  checks, dependencies and acceptance steps to the persistent build queue
  (`scripts/build-queue.py`; installed helper in the Git common directory).
  The configured builder chat processes FIFO, sends queue/start/result messages
  to the originating sessions and alone integrates/packages/promotes. These
  queue messages are user-authorized. Workers follow the result and report
  issues without starting competing builds. Follow the runbook for CLI inboxes,
  pending installs, recovery and the five-minute builder automation.
- The builder holds the shared `exodia-integration.lock` in
  `git rev-parse --git-common-dir` for protected operations. Queue claims never
  replace that lock or any validation gate. Preserve all other sessions' WIP;
  use a clean integration worktree when the primary checkout is occupied.
- Review overlaps, validate the final combined candidate and merge through a
  PR with exact head/base checks. Routine checked integration/local refresh
  needs no repeated approval. Public publishing remains a separate action.
- Build a production candidate without interrupting the installed app. Verify
  its signature/identity against the installed app and require a newer build
  number without downgrading the display version. Keep the last working
  bundle. The user authorized automatic normal restarts outside meetings on
  2026-10-20, accepting interruption of other work. Check the current meeting
  gate from the shared procedure; active/suspected meetings or an unknown
  result defer silently without repeated saved/idle questions. Never force-quit.
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
       -> DropTake.begin latches the mode and the feature route (dropFast or
            dropSmart) when the take starts; Retry and recovery read the
            latch, never the current preference
       -> realtime STT via TranscriptionSessionFactory
            (route of the take's feature, Settings -> API & Models):
            FeatureRouteResolver turns the feature's route (provider account +
            model, AIRoutingStore) into a ResolvedRoute with the account's
            Keychain key; RealtimeAdapterFactory builds the adapter. Your key
            (BYOK) only: direct to the provider (Streaming/BYOK/): Soniox
            (default), Deepgram, ElevenLabs or a self-hosted endpoint speaking
            the OpenAI Realtime protocol. OpenAI itself is not offered; a
            legacy OpenAI choice resolves to Soniox. A server route has no
            default host: a missing or unparseable base URL fails
            (.invalidBaseURL / .missingBaseURL) before any socket opens, never
            reaching api.openai.com. WHY:
            .project-docs/decisions/2026-10-18-no-default-realtime-host.md
            A feature without a route (Not set: never chosen on Apple Silicon,
            the retired Local route, or its key removed), or whose key is
            missing or unreadable, throws .notConfigured / .missingKey and
            opens Settings -> API & Models on that feature's row; nothing
            moves to another provider on its own. Deepgram's language policy
            is checked before the key (invalidLanguageConfiguration). WHY:
            .project-docs/decisions/2026-10-18-remove-local-models.md,
            .project-docs/decisions/2026-10-19-api-and-models.md
       Soniox Stop: drain all captured audio -> 200ms PCM silence -> explicit
       finalize + text EOF. A final <fin> acknowledgement completes the take;
       finished=true also completes it. The 10s watchdog remains the backstop.
       -> cleanup (PostProcessor, route of dropSmartCleanup):
            OpenRouter with the user's key / a custom OpenAI-compatible
            server (Ollama, LM Studio, vLLM) through DirectLLMRouteResolver.
            The mode is captured at take start:
            Fast bypasses the LLM; Smart requires processed text and never
            silently pastes raw speech after a cleanup error or empty result.
            Smart failures retain the transcript in memory and show Retry with
            the original mode and target; configuration errors open API & Models on
            the Drop Smart cleanup row.
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
            take goes to the provider of the feature that led it (Drop Fast
            or Drop Smart; agent batch voice: Agent voice) in Settings ->
            API & Models, with that provider's own Keychain key and its
            recorded model from the built-in registry (Soniox file API, Deepgram
            pre-recorded, ElevenLabs speech-to-text, self-hosted
            /v1/audio/transcriptions over https), with the realtime
            request's language choices. No route for the feature, no key for its
            provider, no recorded model for it, or a server URL without a
            host = unavailable, never another provider. Soniox polling stops after
            30s; its file, then its job, are deleted after every outcome.
            WHY:
            docs/decisions/2026-07-26-empty-batch-is-silence-not-offline.md,
            docs/decisions/2026-06-24-deliveryfailed-escapable-and-retry-robust.md,
            .project-docs/decisions/2026-10-18-provider-batch-transcription.md
       Transcript join (BYOKTranscriptJoin): Soniox tokens carry their own
            spaces = verbatim join; word-level providers = word-boundary join.
            WHY: docs/decisions/2026-07-22-hub-token-join-and-batch-recovery-deadline.md

Agent flow (OpenCode + OpenRouter or Anthropic):
  User -> Right Command tap (text) / hold (voice) -> RightCmdGestureMonitor
       -> voice: the same STT factory as Drop, route of agentVoice
       -> OpenCodeProvider -> opencode run --format json --model
          <openrouter|anthropic>/<selected-model> --dir <local workspace>,
          prompt on stdin; provider and model come from the agent feature's
          route in AIRoutingStore
       -> complete text/tool events rendered progressively in the island
  Settings -> Agents installs an app-managed OpenCode binary from its official
  GitHub release after SHA-256 digest verification, or locates an existing CLI.
  The agent's key and model are chosen in Settings -> API & Models (the
  Agent row: OpenRouter from the live catalog or an exact ID, or Anthropic
  from its /v1/models list); the Agents tab shows "Model: <provider> · <id>"
  with Change in API & Models, and Save & connect only checks the local
  version and the free key endpoint of the route's provider (OpenRouter
  /key, Anthropic /v1/models). Connecting does not submit a model request.
  Keys are the Keychain items byok.openrouter.llm_api_key and
  byok.anthropic.api_key and enter only the child process environment
  (OPENROUTER_API_KEY or ANTHROPIC_API_KEY), never a credential JSON file or
  argv. The runtime enables only the route's provider, declares the selected
  model with its limits and tool support from the provider catalog (so
  OpenCode keeps context compaction), disables sharing/default plugins/
  automatic updates and excludes inherited provider credential/config
  environment variables. Anthropic is offered for the Agent row only, not
  for Drop Smart cleanup or Meeting notes. WHY:
  .project-docs/decisions/2026-10-19-api-and-models.md
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

Translation tools:
  Translate and Subtitles are optional catalog action tools opening one native
  floating window (TranslationWindowController). TextTranslationModel cancels
  edited/replaced requests and rejects late results; automatic text direction
  is RU to EN for Cyrillic input and EN to RU otherwise. Explicit targets use
  AppLanguage. LiveSubtitleModel captures only CoreAudio system audio, never
  the microphone, on the subtitlesAudio real-time route; final-only phrases
  go to its independent subtitlesTranslation LLM route. API & Models groups
  Subtitles Speech/LLM selectors; typed text uses only translation. New routes
  start unset. Migration v2 copies the previous shared text route once only
  for configured subtitles; later edits, clears and launches stay independent.
  Partial v1 documents expose this split in memory without rewriting raw bytes;
  their first real edit retains a backup and persists the split before the edit.
  Never borrow other routes at runtime or migrate standalone credentials.
  Eight queued phrases, forty retained lines and a bounded audio relay stop
  visibly on backlog. Stop uses opt-in CoreAudio terminal EOF after capture
  quiescence and an IO queue barrier, then naturally drains the relay before
  provider endInput. Ordinary meeting/VAD stop keeps streams reusable; hardware
  start/stop/route restart are serialized. Cancel, window close and sleep
  tear down capture and requests. No audio/history is saved. Visible translation work
  (including unsent input) or an active session blocks app-initiated update restart. Guide: docs/translation.md. WHY:
  .project-docs/decisions/2026-10-20-translation-tools.md

Meeting Notes:
  Meetings opens an overview of the five newest notes with a History button.
  History keeps the full date-grouped list. Back from a note preserves its list
  origin; the Settings Meetings entry and direct note links return to overview.
  Both use MeetingListModel and retain refresh, status and confirmed deletion.
  Load failures preserve existing rows and offer Retry. The vertical overview
  layout leaves room for future Meeting Assistant presets without showing
  unfinished controls. UI rationale and behavior: docs/DESIGN.md.
  Always-on detector (mic activity + CoreAudio system audio + FluidAudio
  Silero VAD, the only remaining Core ML model, downloaded from Hugging Face
  on the first speech check; fires only when a recognised meeting app writes
  the mic)
       -> island nudge: Take notes / Skip (20s) -> MeetingRecorder (mic +
          system audio, 16 kHz PCM16; the system-audio tap exists only while
          recording, WHY: docs/decisions/2026-06-16-system-audio-tap-on-record-only.md)
       -> processing: BYOK processor only (routes of the meetings and
          meetingNotes features: Soniox file API with speaker-attributed
          turns and durable job/transcript checkpoint; other providers use
          their adapters, then the LLM route the user chose for notes).
          Speaker labels come from the provider; there is no on-device
          diarizer. Without a route for Meetings and Meeting notes
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
  the 30s startup grace). Every completed call starts processing immediately;
  an auto-ended part remains a Reconnect candidate for three minutes and any
  detector re-fire inside that window asks "Notes | Reconnect | Skip".
  Reconnect captures a fresh part in a separate staging directory. When it ends,
  the same meeting shows Updating… while the earlier note stays readable; only
  fresh audio is transcribed, and its findings/transcript supplement the note.
  Per-meeting processing order, durable recording receipts/content snapshots and
  versioned additions protect recovery and edits. Both Notes hosts refresh the
  selected note/transcript after the list fetch and preserve its current tab.
  Active drafts defer refresh; Done waits for the latest store-save acknowledgment,
  while Cancel applies the deferred refresh. Speaker labels stay scoped to each
  part. Manual Stop is final; timeout/Skip never resume recording. WHY:
  .project-docs/decisions/2026-10-20-meeting-continuations.md
  A BYOK key read that fails with errSecInDarkWake (no Keychain prompt
  possible: dark wake or the lid closing) defers the meeting instead of
  failing it: no failure event, the earlier failure reason is restored and
  the manifest stays for the next pass (startReady() after a full wake, or
  the next launch). WHY:
  .project-docs/decisions/2026-10-18-meeting-recovery-dark-wake.md

  Internal opt-in research (no Settings controls): the local
  sidekey.meetings.liveTestCapture flag adds a separate Soniox stt-rt-v5 stream
  only when Meetings uses Soniox. Preserve its explicitly chosen value. It saves
  private aligned source PCM, signal activity, final diarized tokens and receipt
  times under Sidekey/meeting-assistant-tests. Normal notes remain unchanged;
  no automatic suggestions are enabled. The independent 100ms test mixer uses
  a 150ms jitter allowance and approximate callback timing; source-role labels
  are experimental. Per-source background calibration warms up for two seconds;
  unique-time speaker anchors check surrounding audio and never override current
  overlap or an opposing source. Meeting mic capture keeps its quiet-input boost
  with a peak limiter and gradual gain release. Guide: docs/meeting-assistant-testing.md. WHY:
  .project-docs/decisions/2026-10-20-meeting-source-noise-floor.md,
  .project-docs/decisions/2026-10-19-live-meeting-test-capture.md

Case secrets manager:
  The Case drawer has a 320 pt content viewport (the outer hit band includes
  its gap/music strip) and retains the notch-derived width. Connected clients
  appear as app icons; clicking one opens that client's policy. An always-visible
  Connect button opens the agent picker, then project scope and Accept/Bypass
  before registration. Codex highlights blue, Claude orange and Cursor white
  on hover/keyboard focus. Search matches project and key names/descriptions,
  including empty projects and General. A matching project shows all its keys;
  key-only matches show only those keys. + Key opens a separate creation field,
  including from a project search result; typing/Return in search never writes. Navigation is white and explanations are
  short. Case has no Doppler integration or import screen.
  All explicitly opened hover submenus survive pointer exit until Back, an
  outside click or bare Escape. The root tools grid follows ordinary hover;
  hardware brightness glances still expire. System authentication and native
  menu/file-picker interaction suspend outside dismissal. Activity/preemption
  policy remains authoritative. UI design: docs/DESIGN.md.
  The encrypted schema-3 vault has projects, descriptions and registered AI
  clients with Accept (stored as approve)/Bypass per app and project. A client's
  allowedProjectIDs is nil for all current/future projects or an explicit set
  (empty denies all). The broker filters listings/ambiguity and enforces scope
  again before value/grant release. Scope/mode changes revoke timed grants.
  Schema 2 migrates without changing existing access; older apps refuse schema 3.
  WHY: docs/decisions/2026-10-20-case-connect-and-scope.md. `Contents/Helpers/whytap`
  exposes `case ls`, `case run [-p project] [--only A,B] '<command>'` and
  names-only `case mcp` (`WhytapCaseKit` / `WhytapCLI`). `case_list_keys(query:)`
  searches authorized key names/descriptions and project names directly; a known
  key uses `case run --only KEY` without listing projects first. The app's local Unix
  socket broker accepts only its bundled helper by audit-token cdhash and
  dynamic validity. It validates every bundled architecture and compares the
  running peer with a valid signed slice, including x86_64 under Rosetta. It
  resolves the caller from its process ancestry; Developer ID identities
  require an Apple anchor. Unregistered known AI clients are refused; human
  requests require Touch ID. Before releasing values or creating a timed
  grant after authentication/approval, the broker revalidates the current
  caller, registration and project. Revoking or rebinding a registration
  invalidates its pending requests, including queued approvals.
  Approve uses a non-activating island panel with physical Y/N/A/Escape keys,
  300 ms of keyboard quiet before arming, a 60 s timeout and memory-only timed
  grants. Temporary Bypass is a separate button beside a native editable
  1–240 minute field (default 15), without stepper arrows; the bottom row has
  Deny/Allow only. The command's native hover help contains its full original
  text. While editing minutes the approval keys are suspended; Return commits
  the edit and Escape restores its starting value. Invalid drafts disable timed
  approval and revert to the last valid value on blur. Explicit field focus is
  released on prompt replacement/hide. Buttons expose hover/pressed/focus and
  disabled states. Each new prompt resets its duration. Registration configures the client's names-only MCP entry. The
  helper injects authorized values into the child command's environment and
  applies best-effort masking to stdout/stderr. Deliberately transformed
  output, files and values shorter than four bytes can expose values; this is
  protection against accidental transcript leaks, not a command sandbox.
  The broker's decrypted vault cache outlives the panel's idle lock. WHY:
  docs/decisions/2026-10-19-case-secrets-broker.md

Hover capsules and materials:
  The 2026-10-17 user correction requires hover and the compact island to have
  exactly the same width, with three smaller capsules per row. Follow the actual
  notch-derived compactWidth (310/312 pt examples), not a fixed 457 pt drawer.
  IslandHoverPanelControl.swift defaults to a 90x52 foreground capsule with a
  30 pt white icon disk with 17 pt blue symbols and a normal-case 11 pt title.
  No small status captions are drawn; current values remain in VoiceOver.
  Record lights its icon red with a soft glow while recording, alongside the
  existing right-wing indicator. The grid supplies each instance's exact width through
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
  Settings stays last; persistence remains. Feature hotkeys use stable tool IDs.
  Settings Toolbox keeps a fixed header outside the catalog and tool pane.
  Saved tools scroll horizontally; Add and locked Settings remain visible.
  Add accepts drops and offers a click chooser. Catalog tiles remain selectable
  and draggable when pinned; their header/context menu supports Add/Remove.
  Translate/Subtitles embed the shared translation models in compact views;
  History disables the island keyboard-paste monitor; Monitor and Record expose
  working panels. Other tools have explicit actions instead of blank panes.
  Embedded translation has token-based ownership, cancels on departure/Settings
  close unless its floating window is visible, and blocks update relaunch while
  visible. WHY: .project-docs/decisions/2026-10-20-toolbox-mini-apps.md.
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
  .openPanel(.monitor). Capsule, catalog search and feature hotkeys all open
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
  (a notice, or the battery time left). The switch is the Settings MacSwitch
  at its 30x18 compact size, blue while on: the island is never the active
  app's key window, where the native switch draws its on state gray. The strip
  is 68 pt (76 pt band, 126 pt with music) and needsKeyboardFocus for its
  controls. Opened from a lower tile, the band keeps the previous height as
  transparent hover space under the top-aligned drawer until the pointer is
  over the drawer's final frame (onContinuousHover with
  IslandView.releasesHeldHoverZone): the shrinking drawer's animated frame
  still covers the held zone, and releasing there closed the drawer under a
  quick move up from the third row.
  ScreenBrightnessController follows the island display (IslandScreenResolver)
  and reads/writes its backlight through private DisplayServices (dlopen); an
  unreadable display gets a disabled slider and no switch. Showing the strip
  only reads, polling every 0.5 s while it is visible or Extra is on; a pinned capsule
  refreshes its NN%/Extra VoiceOver status when hover opens. Extra exists only
  for potential EDR headroom > 1.01 and never writes the backlight. As Vivid
  does it, GammaBrightnessBoost scales the display's own transfer table by
  min(1.45, the sRGB-encoded current headroom), Vivid's measured factor on the
  same panel (white about 2.35x SDR), and BrightnessHeadroomTrigger keeps that
  headroom engaged: a click-through shielding-level 1x1 pt window in the
  display's top-right corner, hidden by a built-in display's rounded corner,
  with an rgba16Float extended-linear MTKView cleared to 2 and sharingType
  none. The display applies the table after WindowServer composites, so an app
  switch cannot dim it; the former full-screen multiply layer dimmed on every
  ⌘Tab. Nothing is written until the headroom exceeds 1.05 (none within 5 s
  ends Extra as unavailable). While the headroom first rises or returns, each
  step is followed at once; any other change applies once it holds 1.5 s.
  Without headroom the display has exactly its own table (a factor within
  0.005 of none is none) and Extra stays on; its current table, a new
  profile's included, is the one boosted when the headroom returns. A table
  already above SDR white (Vivid) or rewritten by another app is left alone
  and ends Extra with "Another app is adjusting this display."; a reset by a
  reconfiguration or profile change is boosted again, and a third reset within
  10 s counts as another app. Ending or suspending gives a table back only
  while the display still has the boosted one. BrightnessBoostFrameTimer presents a trigger
  frame every 0.2 s, strip open or not, then checks the table: without focus
  WindowServer keeps the headroom only ~0.8 s after the last frame. Frames
  pause during display sleep, system sleep and another user's session, each
  until its own end notification, and a gap over 1 s between frames restarts
  the 5 s wait for headroom and the 1.5 s hold; another user's session also gets the
  display's own table until this one is active again. Extra is a fixed boost;
  any backlight decrease ends it, including native brightness keys, automatic
  brightness and idle dimming with the strip closed. The first slider decrease
  or intercepted brightness-down press only ends Extra, leaving the backlight
  and slider unchanged for that whole drag or held press. The next adjustment
  lowers the backlight normally, including accessibility adjustments and fine
  key steps; outside changes
  are detected within the 0.5 s poll, after the 0.75 s write-settle window.
  Float readback round-off is ignored. Enabling Extra reads a fresh baseline;
  increasing brightness never enables it. Its switch (strip or Settings) also
  ends it, as do serious thermal state, a
  display change or lost EDR support, another app's table, a boost failure and
  quit. Ending it gives the display its own table back (ColorSync's if Quartz
  refuses it; Quartz also restores it when the process exits) and leaves the
  backlight as it is. Extra is never persisted or resumed after relaunch.
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
  pane appears. They are the Mac's keys, not a Whytap hotkey: no Help row.
  BatteryRuntimeMonitor reads IOKit power sources and AppleSmartBattery once a
  minute from launch, and every 5 s while the strip is visible. Each sample is
  the system load that PowerTelemetryData's accumulators average between two
  updates 30-180 s apart (a longer gap such as sleep adds none), with the
  built-in display's light averaged over the same span: level squared, times
  the light of the table factor Extra currently applies to it (x2.35 at 1.45,
  x1 without headroom), 0 with the lid closed. A factor change on its own is
  counted at the next reading (5 s with the strip, 60 s without). Over the last 30 minutes the load's
  slope over that light (ridge toward a 5 W prior, 1-15 W, at most 80% of the
  mean load) moves the display's share to the current light, so a slider or
  Extra change recomputes the line at once without reading the battery. On
  battery macOS's estimate comes first until five samples exist, adjusted the
  same way from the light of the minute before its reading (about what macOS
  averages) to the current light; on power the line shows the
  time if unplugged. The history stays in memory: battery readings and key
  events are never written to disk, logged or sent. WHY:
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

whytap:// links:
  CFBundleURLTypes registers the whytap scheme; AppDelegate handles kAEGetURL
  (registered in applicationWillFinishLaunching, queued until launch ends).
  WhytapLink parses only whytap://tool/<HoverTool rawValue> and
  whytap://settings/<SettingsWindowTab rawValue>; its switches over both enums
  are exhaustive, so a new tile or tab needs a destination to compile. The enums
  are the public registry of linkable places: never rename raw values. A link
  only shows a place: inline tools open their HoverPanelRequest, navigate tools
  and tabs open Settings with setHighlight, Planner/Translate/Subtitles windows
  open idle, Drop Mode/Record/Screenshot select their Toolbox pane
  (SettingsWindowSelection.focus) and Quit highlights the Quit row. Unknown ids
  or kinds only wake the island; other schemes, credentials, ports, empty or
  extra segments and non-alphanumeric ids are rejected and not logged. WHY:
  .project-docs/decisions/2026-10-20-whytap-links.md

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
  Missing artwork triggers a background get --micros with a 2s deadline,
  one request at a time and a 5s retry cooldown. Recovery copies only the image
  into current metadata, matching player/process/content item/title/artist/album
  and the request generation; track changes, clears and lifecycle resets reject
  stale results. No Automation prompt is added. WHY:
  .project-docs/decisions/2026-10-19-nowplaying-artwork-recovery.md

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
  Apple Developer/notarization. The app is signed with Whytap's self-signed
  community certificate when Resources/community-signing-certificate.pem is
  committed (stable designated requirement, so TCC grants survive updates),
  otherwise ad hoc. Source dev builds (9999 / -dev) do not start the binary
  updater. WHY:
  .project-docs/decisions/2026-10-17-community-updates.md,
  .project-docs/decisions/2026-10-19-community-signing-identity.md,
  docs/decisions/2026-06-17-update-download-on-action.md,
  docs/decisions/2026-07-08-update-download-spinner-and-post-relaunch-updated-indicator.md
```

Presentation: Settings -> API & Models has four internal tabs: API keys,
Models (the initial tab), Costs and API hints. API keys holds the provider keys (Soniox,
Deepgram, ElevenLabs, OpenRouter, Anthropic for the Agent row, and the user's
OpenAI-compatible servers) and one model per AI feature (Drop Fast, Drop
Smart, Drop Smart cleanup, Meetings, Meeting notes, Agent, Agent voice, Voice
search); Local was removed. Models come from provider catalogs plus the
built-in registry; a model outside the registry is checked with a synthetic
probe when picked or on Check now. The first launch migrates the old choices
into per-feature routes (AIRoutingMigration) and leaves the old UserDefaults
keys untouched so a rollback sees them; nothing is switched to another
provider or model automatically. WHY:
.project-docs/decisions/2026-10-19-api-and-models.md Preserve saved
processing routes: never switch where existing users send audio or text. A
retired Local choice shows "not set up" banners until the user saves a
provider. WHY: .project-docs/decisions/2026-09-10-byok-and-local-builds.md,
.project-docs/decisions/2026-10-18-remove-local-models.md

Costs: the local ai-usage.sqlite journal records only feature/provider/model,
request ID, time, duration, currency and expense metadata from actual runtime
calls. Historical routes are captured before sending; switching models does not
rewrite past usage. Only used feature groups appear for the selected local-date
period; hover/click/keyboard focus reveals their models. One Price column
retains explicit USD and ElevenLabs credit units, both when mixed. Each visit
starts at This month; matching neutral From/To controls open a dismissing native
calendar. No permanent bottom explanation or sticky text-segment highlight. OpenRouter response costs and exact matched ElevenLabs
analytics debits are reported; Soniox public hourly equivalents and OpenCode's
computed step prices are estimates. Missing prices stay unavailable, never zero;
partial totals show +. No account-wide balance deltas or USD-to-credit conversion.
Tracking starts with this update; synthetic model checks are excluded. WHY:
.project-docs/decisions/2026-10-20-feature-costs.md

API hints: the fourth tab contains four provider offer cards with brand marks,
allowances and official links. It distinguishes starter credit, monthly allowance
and paid-plan benefits. Add API key switches to API keys and opens the existing
form. Opening hints never checks balances or changes routes. WHY:
.project-docs/decisions/2026-10-19-api-hints.md

Model selection uses ModelPicker: a searchable native popover sharing the 30 pt
MacPopupLabel. Name/size terms match in any order (`qwen 27`, `qwen27`), ignoring
case/separators. Search never changes routes; explicit picks retain verification.
Up/Down and Return choose enabled results; Escape clears then closes. WHY:
.project-docs/decisions/2026-10-20-model-search.md

Other selection menus use MacMenu/MacPopup: a 30 pt neutral control with 8 pt corners
and one down chevron, retaining native menu tracking. Provider menus,
Backup, display, account/key sheets and translation share this label; the
screenshot toolbar uses its AppKit counterpart MacPopupButton. Notifications
centers the menu and enable switch, moving Notification type into the adjacent
question-mark tooltip/popover. Bindings and saved selections are unchanged.
WHY: .project-docs/decisions/2026-10-20-compact-selection-menus.md

Settings follows macOS light/dark appearance while open. MacSettingsTheme owns
dynamic SwiftUI/AppKit colors; the shell uses inset groups and text-only sidebar
rows with a 140 ms background hover fade (immediate with Reduce Motion).
MacSwitch adapts the supplied glass switch in SwiftUI with click/drag,
keyboard and native Toggle accessibility, respecting Reduce Motion/Transparency.
The island keeps its compact blue switch and explicitly dark Toolbox previews.
UI decisions and verification limits: docs/DESIGN.md.
API & Models separates function rows; missing setup uses a static orange contour
and soft glow instead of Not set/triangle status lines. Actual problem text and
recovery actions remain. Shared settings rows use spaced, full-point dividers.

First run: no sign-in and no onboarding wizard. Launch and reopen show the
island immediately. Configure provider keys and endpoints in
Settings -> API & Models (the agent's model is chosen there too; Settings ->
Agents keeps the OpenCode install and connect), and permissions in
Settings -> Permissions. A feature can request the permission it needs when
invoked. Drop without a chosen provider, key or endpoint opens
Settings -> API & Models on that feature's row. Settings opens on API &
Models; screenshot protection is in
Other (default off). The former tour, resume state, preview target and
voice demos were removed. WHY:
.project-docs/decisions/2026-10-17-local-workspace.md

Notify includes a built-in Meeting notes source, enabled by default for new and
existing users unless explicitly switched off. MeetingReadyNotifications sends
successful newMeetingAvailable events to the local queue/history with the
packaged Whytap app icon in color. Settings -> Notifications has a persistent switch; Notify ->
Sources also has the switch. An optional internal meetingID in the archived
event opens that exact note through SettingsWindowController.selectNoteMeeting;
scripts cannot supply this target. Failed processing does not announce success,
and loading history does not replay old popups. WHY:
.project-docs/decisions/2026-10-20-meeting-ready-notifications.md

Notify: agent-configured local scripts emit JSON lines with title, body, event
ID, optional link, color, logo and duration. NotifyScriptSupervisor reads private
sources/<id>.json manifests, supervises child process groups only during the app
lifetime, restarts with bounded backoff and stops on disable, removal, sleep or
quit. A perl stdin-EOF guard (NotifyProcess.parentWatchGuardScript) leads each
group and ends it when the app is killed or crashes. WHY:
.project-docs/decisions/2026-10-19-notify-parent-death-guard.md. No backend or built-in provider connectors are restored. The original
IslandNotificationPill / nonactivating panel sits left of the island, using the
selected screen and screenshot-protection preference. All notifications use
cards (8 seconds by default), queued in arrival order with at most 33 presented
or queued events. Hover pauses dismissal, brightens and enlarges the card by 3% from its
top-trailing corner (except with Reduce Motion). Transparent panel overflow
fits the transformed card on notched and unnotched displays, and the hosting
hit region follows its visible size. The 8 pt island gap stays fixed. Small notification
rendering, stacks and type controls are removed. Legacy presentation fields are
ignored; missing titles use the source name, preserving former icon-only sources.
Notify retains 500 history events. Unseen events show a red dot only on Notify in
hover/search until history is opened, including after a restart. Clear All is
text-only and immediately clears history and current events, preserving sources.
NotificationSoundSettings persists Off (default), Glass, Ping or Pop per source;
Settings selection previews the sound. LocalNotificationHub signals fresh accepted
arrivals within the presentation limit. Duplicates, restored history and suspended
delivery stay silent. NotificationSoundPlayer bounds bursts to one sound per
0.75 seconds and never overlaps sounds; scripts cannot enable them. WHY:
.project-docs/decisions/2026-10-20-notification-cards-and-sounds.md.
Existing Codex chats support click-through
via codex://threads/<thread-id>; no query/fragment or new-chat/action links.
Claude Desktop local Code sessions accept
claude://code/continue?session=local_<uuid>, restricted to that one parameter.
Native sessionId is resolved from Desktop metadata by the hook's cliSessionId;
it is not the hook ID with a prefix. Other Claude routes are rejected.
Bundled logos include codex and claude-code. Actual agent event sources are
configured separately. WHY:
.project-docs/decisions/2026-10-19-icon-notifications.md. Hover pauses dismissal.
LocalNotificationHub persists up to 500 events, deduplicates scoped IDs and keeps
content in history; unreadable history is never silently overwritten. Notify
opens through hover search, Toolbox and assigned feature hotkeys without
changing saved layouts. Settings -> Notifications lists connected sources with
their name, logo, runtime status and individual persistent enable switches.
Disabling stops the source and keeps its setup/history for re-enabling.
Agents get a resolved setup-guide path on every turn.
Guide: docs/customization/notifications.md. WHY:
.project-docs/decisions/2026-10-19-script-notifications.md

To-do opens a compact inline hover list with Return-to-add, click-to-complete/reopen
and a History mode with completion date/time. Completed tasks move below active
ones for the current opening, then appear only in History. Native tooltips expose
full truncated titles. Drafts survive closing; saved Toolbox slots remain unchanged.
Calendar opens the native Planner window. PlannerStore atomically saves private local tasks
and Whytap events; unreadable archives block writes. CalendarConnections combines
selected EventKit calendars with direct Google Calendar, Microsoft Graph (including
Teams links) and Zoom Calendar Service connections. Remote events are read-only;
visible-range recurrence is provider-expanded, refresh runs only while the calendar
view is visible, and matching UID/occurrence bounds collapse duplicate sources.
OAuth uses browser S256 PKCE/state, a numeric loopback listener (Microsoft redirects
to localhost), and Keychain credentials with durable refresh-token rotation.
Short-lived access tokens stay in memory and are excluded from backup; only a
refresh-token/client change updates the saved authorization. Token rotation alone
does not create a settings version or full backup; subsequent backups capture the
latest token, and restored sign-in can require reconnecting. No
shared OAuth registrations are created by the app itself; the owner supplies
registered native clients during packaging through configure-calendar-clients.py.
Live accounts require provider setup and separate acceptance. Encrypted backups
include local Planner content, calendar metadata and saved credentials. Old backups
preserve current calendar settings. A visible Planner, inline To-do, or retained task draft
defers update restart and restore; ordinary backups still run. Closing the window
stops calendar polling; another tool hotkey preserves an attached editor. Tests
use fake providers and temporary stores. Guide:
docs/planner.md. WHY: .project-docs/decisions/2026-10-19-planner.md,
.project-docs/decisions/2026-10-20-todo-hover.md

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
later cannot honor the lease. The Settings footer shows only the actual app name
and display version, separated from website and GitHub links by a thin rule.
All footer text uses the same size; the links have icons, a pointing-hand cursor,
hover/press highlights and destination tooltips. Detailed build identity stays
in bundle metadata, outside this compact footer.
WHY: .project-docs/decisions/2026-10-19-one-running-copy.md
`--installation-check` loads the packaged executable and verifies resources
without starting the app runtime. User guide: `docs/install.md`. Policy:
`.project-docs/decisions/2026-09-10-public-installation.md`.

Targets: library `Sidekey` (all app code) + thin executable `SidekeyApp`
(product `Sidekey`, `SidekeyAppMain.run()`) and `SidekeyTests`. Flavors: `prod` (default) and `beta` (`-DBETA`: separate
bundle id, keychain service and feed), see `Sources/Sidekey/BuildConfig.swift`.

## User artifact backup

Settings → Integrations connects GitHub using an existing CLI login or an access
token. Settings → Backup shows its synchronization status, a GitHub Releases link and Back up /
Restore backup. Back up always includes all supported user data and stored keys,
uploads and verifies ciphertext, then displays the recovery code without a
paste-back step. Restore takes only that code and stages every included section
from the newest completed GitHub version without a selection/confirmation wizard.
A normal quit and relaunch applies it; the running stores are never replaced.
There are no normal-page backup settings, management/history disclosures or
folder picker. Existing automatic schedules, folder destinations, local encrypted
history and unfinished maintenance recovery remain compatible internally.
A successfully created GitHub backup enables automatic sync. Existing verified
GitHub copies adopt it once; later explicit cancellation pauses it across restart.
The 60-second poll detects settings/credential and artifact changes, waits for idle
and spaces attempts at least 120 seconds apart. Pending edits, failed transfers,
pauses and maintenance never show Backup synced. Background sync keeps the same
recovery credential without revealing it. WHY:
`.project-docs/decisions/2026-10-20-backup-auto-sync.md`.
GitHub connection checks are read-only; Connect is the only action that can
create the private Exodia-Backup repository. Connection alone never backs up data.
API & Models routes, server registrations and their provider keys are included.
Short recording chunks use the archive entry ceiling rather than a separate
4096-file limit. WHY:
`.project-docs/decisions/2026-10-20-simple-github-backup.md`.

ArtifactBackupEngine receives the actual live MeetingsStore/SQLiteHistoryStore
instances, whose export methods freeze database/sidecar generations. Restore
validates into a parked transaction and applies before any stores or jobs open,
with durable rollback of files, preferences and provider keys. Committed
transactions resume finalization after a crash; replaced generations and their
encrypted before-state keys are retained. Never discard an unfinished rollback
because Keychain retries are exhausted. The startup recovery UI accepts the
saved code without opening stores. Case merges into the target's own vault/key. Imported
jobs and Notify/Monitor configurations stay inert pending review. No Whytap
backend, automatic GitHub Actions, silent source changes or forced restart.

Guide: `docs/backup.md`. WHY:
`.project-docs/decisions/2026-10-19-config-backup.md`.

## Screenshots

Screenshot is an action tool in hover search/Toolbox with an optional named
hotkey. ScreenshotCoordinator explicitly captures displays with ScreenCaptureKit,
then shows a frozen selection canvas and one horizontal native toolbar with
inline contextual settings, Copy and Download. Return copies and closes (the full display if there is no crop), waiting for pending Blur. Download writes collision-safe timestamped
PNG files into Downloads and shows the actual filename without closing. Arrow,
Shape,
Pen, Text and Blur are immediate; secondary tools, OCR, pin, output size and
system sharing live in More. Blur defaults to Text and numbers, including
standalone digits, using fast Vision regions plus a bounded isolated-glyph atlas
without language correction; accurate OCR belongs to Copy text. Dark crops are
normalized only for detection; output keeps original colors. Each text region
gets its own blur strength, with stronger masks applied last. Crop-first compositing, Blur and PNG export run off the UI
thread; a shared hardware Core Image context avoids per-gesture setup.
Entire area is the alternative. Detection is
best-effort and the visible result must be checked. Exports flatten edited
pixels; Copy text analyzes those pixels too. No capture is persisted before an
explicit export. Active editing/processing/dialogs block app-initiated update
restarts; screen/Space changes and sleep cancel stale captures. This system OCR
is separate from the removed app-managed speech/LLM models. Guide:
`docs/screenshots.md`. WHY:
`.project-docs/decisions/2026-10-20-screenshot-toolbar.md`.

## Permissions

- **Screen Recording** for explicit screenshot capture (Screenshot tool only).
  Settings -> Permissions shows a green circled checkmark when granted, or
  the same Allow button used by the other permissions when missing, without
  status chips or an action on a granted row. Request with
  `CGRequestScreenCaptureAccess` only on Screenshot
  invocation or that Settings action, never at launch or refresh. Returning
  from System Settings refreshes the status; it never gates launch/Drop readiness.

- **Accessibility** gates `NSEvent.addGlobalMonitorForEvents`
  (`RightCmdGestureMonitor`; `EscapeCloseEventMonitor` is a passive bare-Esc
  close for the visible agent answer, WHY:
  docs/decisions/2026-07-02-escape-close-passive-monitor.md), the AX check
  of the focused field (`PasteTargetValidator`) and, empirically, the active
  `CGEventTap` in `SpaceHoldMonitor` and the optional Brightness keys tap
  (`BrightnessKeyEventTap`) and the Case approval tap (`CaseApprovalKeyTap`,
  only while a prompt is queued; clicking remains available without the tap).
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

Whytap stays open source and uses ready-made community builds for normal installs
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
modified app. Older Whytap installs using the retired update host need a manual installation.
Exodia GitHub URLs redirect to the renamed repository; preserve releases and
archive names already published.

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
`HotkeyTapCombo` uses uppercase US English physical-key labels regardless of
input layout, including live recording and previously saved non-English titles.

## Invariants

1. **No Whytap-owned services.** The app never contacts a Whytap backend,
   has no account and sends no telemetry. Network traffic is limited to
   the meeting detector's Silero VAD download from Hugging Face, providers
   and monitoring sources the user configured (including their credential store),
   notification sources accessed by user-configured local scripts, calendar providers
   explicitly connected by the user (Google, Microsoft and Zoom), OpenCode's own provider
   traffic, the model catalogs and free key checks of providers the user added
   a key for, OpenRouter's provider list (latency, throughput) for a model
   selected on an OpenRouter route, synthetic model probes (silence or a one-word prompt, never user
   audio or text) sent only to that provider when a model is picked or on
   Check now, its official GitHub release download, `google.com` opened in the
   browser, the Sparkle feed on GitHub Releases, and optional encrypted backups
   to the user's own GitHub repository or selected sync folder.
   `Tests/SidekeyTests/CloudRemovalTests.swift` fails the build on any
   Whytap hostname or removed cloud symbol under `Sources/`.
2. **Keys and content never leave through logs.** Active BYOK keys live in
   the Keychain (`BuildConfig.keychainService`). Optional recovery archives
   include them only inside locally authenticated encryption under an
   independently saved recovery credential. `os_log` never receives
   transcripts, prompts, replies or keys (`LocalPathLoggingInvariantTests`).
   Key contents read by the hotkey tap or the Brightness keys tap are never
   logged or persisted.
3. **No on-device models and no silent route change.** Speech, cleanup and
   meeting processing run only on providers or endpoints the user chose. A
   stored retired `local` level, or no stored level on Apple Silicon (where
   Local was the default), reads as not configured even when a key is stored;
   Intel keeps its Your key default (`SelfKeyPreferences`,
   `RetiredLocalRouteTests`). Each feature's data, including its fallback and
   probe, goes only to the provider of its own route in Settings -> API &
   Models; a removed key leaves the feature Not set and moves nothing. WHY:
   .project-docs/decisions/2026-10-19-api-and-models.md FluidAudio stays only for the meeting detector's
   Silero VAD; launch removes the retired models' weights under
   Application Support/Sidekey once per flavor and never touches FluidAudio's
   cache (`LegacyLocalModelCleanup`, WHY:
   .project-docs/decisions/2026-10-18-legacy-model-cleanup.md). There is no
   paid gate anywhere.
4. **Sparkle never shows a window.** Scheduled checks only show the island
   pill; nothing downloads before the user clicks. Requested downloads may
   install and relaunch while idle. Active meeting recording, dictation or
   agent work or translation defers app-initiated relaunch; becoming idle alone does not restart
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
   Every HoverTool can have an optional named shortcut in Settings -> Hotkeys ->
   Tools, including unpinned tools. `toolShortcuts` binds stable tool IDs, so
   reordering/removing tiles never reassigns keys. New installs reserve no digit
   shortcuts; explicitly saved old slot keys migrate once to their current tools.
   Hints and Help read the same config; clearing/reset persists an empty map.
   WHY: docs/decisions/2026-10-19-feature-hotkeys.md
6. **Case authorizes secret use at the broker boundary.** Only the bundled
   helper receives values for an authorized child command's environment.
   Never put values in argv, MCP responses, client configuration, repository
   files or app logs. Output masking is best effort, not a guarantee against
   deliberate extraction by an approved command. Revalidate current caller
   authority after approval/authentication before granting or releasing
   values. WHY: docs/decisions/2026-10-19-case-secrets-broker.md
