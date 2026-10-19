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
- API keys you enter in Settings → API & Models ("Your key") are stored in the
  macOS Keychain under the app's own service name (`com.rootwise.sidekey`).
  Key values are never shown again after saving and are never written to
  UserDefaults, files or logs. UserDefaults holds only which provider and model
  each feature uses, plus the names and addresses of your own servers.
- Cached model catalogs (a file in the app's Caches folder) and the results of
  key and model checks (provider, model, status, time; never a key, audio or
  text) stay on the Mac.
- Logs go to the unified system log (`os_log`, subsystem
  `com.rootwise.sidekey`). They never contain transcripts, prompts, replies
  or keys; `Tests/SidekeyTests/LLM/LocalPathLoggingInvariantTests.swift`
  enforces that for the provider paths that carry this content.

Project folders are indexed only after you select them in Settings → Projects.
The catalog, notes and SQLite text index stay in the app’s local Application
Support directory. Search is lexical and requires explicit reindexing. The
selected project’s notes and matching source excerpts are included in that
project’s agent requests and can therefore reach OpenRouter and its provider.
Each project has a separate agent workspace and session store. Hidden files,
symlinks, build folders and common credential filenames are excluded from the
index; this is not a complete secret detector. Do not add secrets to notes.

Monitor dashboard snapshots and server connection references also stay locally.
The app runs a fixed read-only Linux metrics collector through SSH; dashboards
cannot embed commands or executable HTML. UT/Sferyx configuration belongs to
the user’s local files and is absent from the source repository.

## What can leave the device, and only when you choose it

| Route | Where data goes | When |
|---|---|---|
| Meeting detector (FluidAudio Silero VAD) | nowhere; a one-time download from Hugging Face fetches the model | the first time the detector checks for speech |
| Your key: speech (Soniox, Deepgram, ElevenLabs, or a self-hosted endpoint speaking the OpenAI Realtime protocol) and text (OpenRouter or a custom OpenAI-compatible endpoint) | the provider or endpoint chosen for that feature in API & Models, with your key (a custom endpoint may need none). Each feature's data goes only to its own provider, including its recovery path; nothing moves to another provider | while the feature's route is in use |
| Agent (OpenCode) | the provider chosen for the Agent row (OpenRouter or Anthropic) and its selected model, using your API key; tool actions may access destinations needed by your request | when you submit an agent request |
| Key checks | the provider of the key: a free request (model list, key or account endpoint) that sends only the key. A restricted ElevenLabs key may need a minimal paid speech request, made only when you save the key or press Check now | when you save a key, press Check now, or open API & Models and the last result is a day old |
| Model catalogs | the public model lists of OpenRouter and Deepgram (no key), and the model lists of Soniox and Anthropic (your key); a custom server's `/models` list. Only the request itself is sent, no audio or text | when you open API & Models and the cache is a day old, save a key, or press Refresh models |
| Model probes | the provider of the feature you are choosing a model for: 1 second of digital silence for speech models, the prompt "Reply with OK." (plus one fictitious tool for agent models) for text models. Never your audio, transcripts, prompts or notes. Costs a fraction of a cent | only when you pick a model that is not in the built-in list, or press Check now |
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
