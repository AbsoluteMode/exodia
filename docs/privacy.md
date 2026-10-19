# Privacy

Whytap has no accounts, no Whytap-operated servers and no telemetry. This
document lists every way data can leave the Mac, so that "no Whytap servers"
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
- API keys you enter in Settings → API & Models ("Your key") are stored in the
  macOS Keychain under the app's own service name (`com.rootwise.sidekey`).
  Key values are never shown again after saving and are never written to
  UserDefaults, plaintext files or logs. UserDefaults holds only which provider
  and model each feature uses, plus the names and addresses of your own servers.
  Encrypted local history and optional recovery archives can also contain the
  Soniox, Deepgram, ElevenLabs, OpenRouter and legacy custom-endpoint keys,
  protected by the independent backup key. No plaintext key export file is created.
- Cached model catalogs (a file in the app's Caches folder) and the results of
  key and model checks (provider, model, status, time; never a key, audio or
  text) stay on the Mac.
- Logs go to the unified system log (`os_log`, subsystem
  `com.rootwise.sidekey`). They never contain transcripts, prompts, replies
  or keys; `Tests/SidekeyTests/LLM/LocalPathLoggingInvariantTests.swift`
  enforces that for the provider paths that carry this content.
- Planner tasks and local Whytap events stay in a private atomic JSON archive
  under Application Support/Sidekey/Planner. External calendar events are held
  in memory while using the unified calendar, without a persistent event cache.
  Calendar OAuth tokens and Google desktop client configuration are stored in
  Keychain; they are not logged. The current encrypted-backup allowlist does not
  yet include Planner content, calendar settings or these credentials.

The Projects feature has been removed. The app does not open the old project
catalog or index, scan registered folders, or attach saved project notes and
source excerpts to agent requests. Existing project-library files and separate
project-agent workspaces are left on disk, unused; they are not migrated into
the regular agent workspace.

Monitor dashboard snapshots and server connection references also stay locally.
The app runs a fixed read-only Linux metrics collector through SSH; dashboards
cannot embed commands or executable HTML. UT/Sferyx configuration belongs to
the user’s local files and is absent from the source repository.

The Display tool reads and sets the display backlight through macOS DisplayServices
and reads the battery charge and load through IOKit, only while its hover strip
is open (plus one level read when hover opens with Display pinned). Nothing
is stored, logged or sent, and it requests no macOS permissions.

Notify stores notification history (up to 500 events), including text, links,
colors and logo names, locally under Application Support. User-configured scripts
can access the external sources required by their integration with the user's
authorized credentials. They run with ordinary user permissions while the app is
open and stop on quit; Whytap does not send notification content to a model or an
Whytap server. Script output is not logged and stderr is discarded. History and
source controls are in Notify. [Script contract](customization/notifications.md).

## What can leave the device, and only when you choose it

| Route | Where data goes | When |
|---|---|---|
| Meeting detector (FluidAudio Silero VAD) | nowhere; a one-time download from Hugging Face fetches the model | the first time the detector checks for speech |
| Your key: speech (Soniox, Deepgram, ElevenLabs, or a self-hosted endpoint speaking the OpenAI Realtime protocol) and text (OpenRouter or a custom OpenAI-compatible endpoint) | the provider or endpoint chosen for that feature in API & Models, with your key (a custom endpoint may need none). Each feature's data goes only to its own provider, including its recovery path; nothing moves to another provider | while the feature's route is in use |
| Agent (OpenCode) | the provider chosen for the Agent row (OpenRouter or Anthropic) and its selected model, using your API key; tool actions may access destinations needed by your request | when you submit an agent request |
| Key checks | the provider of the key: a free request (model list, key or account endpoint) that sends only the key. A restricted ElevenLabs key may need a minimal paid speech request, made only when you save the key or press Check now | when you save a key, press Check now, or open API & Models and the last result is a day old |
| Model catalogs | the public model lists of OpenRouter and Deepgram (no key), and the model lists of Soniox and Anthropic (your key); a custom server's `/models` list. Only the request itself is sent, no audio or text | when you open API & Models and the cache is a day old, save a key, or press Refresh models |
| Model probes | the provider of the feature you are choosing a model for: 1 second of digital silence for speech models, the prompt "Reply with OK." (plus one fictitious tool for agent models) for text models. Never your audio, transcripts, prompts or notes. Costs a fraction of a cent | only when you pick a model that is not in the built-in list, or press Check now |
| Encrypted backup | your private GitHub repository or the folder/sync service you selected; only authenticated ciphertext leaves Whytap | after you explicitly configure and enable Backup |
| Connected calendars | the Google, Microsoft or Zoom account provider you explicitly connect; OAuth authorization and event queries for the displayed date range | sign-in in your browser, then while the calendar view is visible or refreshing; local tasks/events are not uploaded |
| OpenCode installation | official anomalyco/opencode GitHub release metadata and executable | only after clicking Install in Settings → Agents |
| Monitor | the SSH targets configured locally by the user; optionally Doppler to resolve credential references | while Monitor is open; custom collectors run separately under the user’s control |
| Google search hotkey | a `google.com/search` URL opened in your browser | when you press Right Option |
| Sparkle updates | GitHub Releases (`appcast.xml` and the DMG) | hourly check, download only on your click |

OpenAI itself is not offered for speech. An older saved OpenAI choice reads as
Soniox and sends audio there only with a Soniox key you stored; without one,
dictation opens Settings → API & Models instead of recording.

Each provider has its own data-use terms; check them before pasting a key.
Data-use policies depend on the selected provider and its account settings.

## Permissions

- Accessibility: global hotkeys (hold Space, Right Command), detecting an
  editable text field before recording and, only when Brightness keys is
  switched on in Settings → Toolbox → Display, the Mac's brightness keys.
- Microphone: dictation and meetings.
- System Audio Recording: the other side of a call, only while a meeting is
  being recorded. The audio tap is created at recording start and torn down
  at stop.
- Post Event (part of Accessibility on current macOS): the synthetic
  Command-V used to paste.
- Calendars: only after choosing Apple Calendar in Planner's Connect account.
  macOS requires full event access to read selected system calendars; Whytap's
  current native calendar adapter only reads events. Direct Google, Microsoft
  and Zoom connections use their provider's OAuth consent instead.

The hold-Space detector reads keyboard events only to recognise the trigger
key and Escape. The Brightness keys tap receives only system-defined events,
such as the brightness, volume and media keys, and acts only on the
brightness keys. Key contents are never logged or stored.

## Encrypted recovery copies

Backup is optional. Whytap encrypts the portable workspace before copying or
uploading it, including provider keys and independently recoverable Case data.
The recovery code is saved once outside Whytap; a local Keychain copy allows
routine backups without repeatedly requesting it. GitHub authentication is not
the decryption key. The code is excluded from Whytap's clipboard history when
copied through its recovery-code button, marked private for other clipboard
applications, and cleared after two minutes if the clipboard has not changed.
Other applications decide how they handle private clipboard markers.

Restore verifies a whole archive before applying selected groups on the next
normal launch. Imported jobs and executable configurations do not run on their
own. External clipboard file originals, SSH keys and credentials managed by
other applications are not silently copied. [Coverage and recovery](backup.md).
