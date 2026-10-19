# Privacy

Exodia has no accounts, no Exodia-operated servers and no telemetry. This
document lists every way data can leave the Mac, so that "no Exodia servers"
is a verifiable claim rather than a slogan.

## What stays on the device

- Audio captured for dictation (Drop) and for meetings is processed in memory
  and, for meetings, staged as WAV chunks under `~/Library/Application
  Support/` only until your configured provider has transcribed them.
- Transcripts, agent history, clipboard history and meeting notes live in
  SQLite databases under `~/Library/Application Support/`. Delete them from
  Settings, History, or by removing the files.
  Clipboard keeps up to 50 recent text, image and file-path entries across
  restarts, with image attachments stored beside the database. New copies
  evict the oldest excess entries and their images. It does not import the
  existing pasteboard payload on launch.
  History → Clipboard displays the latest 20 retained copies with scrolling.
- API keys you enter ("Your key") are stored in the macOS Keychain under the
  app's own service name (`com.rootwise.sidekey`).
- Logs go to the unified system log (`os_log`, subsystem
  `com.rootwise.sidekey`). They never contain transcripts, prompts, replies
  or keys; `Tests/SidekeyTests/LLM/LocalPathLoggingInvariantTests.swift`
  enforces that for the provider paths that carry this content.

The Projects feature has been removed. The app does not open the old project
catalog or index, scan registered folders, or attach saved project notes and
source excerpts to agent requests. Existing project-library files and separate
project-agent workspaces are left on disk, unused; they are not migrated into
the regular agent workspace.

Monitor dashboard snapshots and server connection references also stay locally.
The app runs a fixed read-only Linux metrics collector through SSH; dashboards
cannot embed commands or executable HTML. UT/Sferyx configuration belongs to
the user’s local files and is absent from the source repository.

Notify stores notification history (up to 500 events), including text, links,
colors and logo names, locally under Application Support. User-configured scripts
can access the external sources required by their integration with the user's
authorized credentials. They run with ordinary user permissions while the app is
open and stop on quit; Exodia does not send notification content to a model or an
Exodia server. Script output is not logged and stderr is discarded. History and
source controls are in Notify. [Script contract](customization/notifications.md).

## What can leave the device, and only when you choose it

| Route | Where data goes | When |
|---|---|---|
| Meeting detector (FluidAudio Silero VAD) | nowhere; a one-time download from Hugging Face fetches the model | the first time the detector checks for speech |
| Your key: speech (Soniox, Deepgram, ElevenLabs, or a self-hosted endpoint speaking the OpenAI Realtime protocol) and text (OpenRouter or a custom OpenAI-compatible endpoint) | the provider or endpoint you selected, with your key (a custom text endpoint may need none) | while the selected route is in use |
| Agent (OpenCode) | OpenRouter and the selected model provider, using your API key; tool actions may access destinations needed by your request | when you submit an agent request |
| OpenCode installation | official anomalyco/opencode GitHub release metadata and executable | only after clicking Install in Settings → Agents |
| Monitor | the SSH targets configured locally by the user; optionally Doppler to resolve credential references | while Monitor is open; custom collectors run separately under the user’s control |
| Google search hotkey | a `google.com/search` URL opened in your browser | when you press Right Option |
| Sparkle updates | GitHub Releases (`appcast.xml` and the DMG) | hourly check, download only on your click |

OpenAI itself is not offered for speech. An older saved OpenAI choice reads as
Soniox and sends audio there only with a Soniox key you stored; without one,
dictation opens Settings → Models instead of recording.

Each provider has its own data-use terms; check them before pasting a key.
Data-use policies depend on the selected provider and its account settings.

## Permissions

- Accessibility: global hotkeys (hold Space, Right Command) and detecting an
  editable text field before recording.
- Microphone: dictation and meetings.
- System Audio Recording: the other side of a call, only while a meeting is
  being recorded. The audio tap is created at recording start and torn down
  at stop.
- Post Event (part of Accessibility on current macOS): the synthetic
  Command-V used to paste.

The hold-Space detector reads keyboard events only to recognise the trigger
key and Escape. Key contents are never logged or stored.
