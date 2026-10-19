# Exodia

Voice input and a voice-driven agent for macOS. Bring your own API keys
(BYOK) or your own OpenAI-compatible endpoint.

Hold **Space** in any text field, speak, release: the transcript is pasted
where the cursor is. Tap **Right Command** to ask your local OpenCode agent
by text, hold it to ask by voice. Choose its model through OpenRouter. Let
Exodia notice your meetings and turn them into notes. All of it without an
account, without Exodia servers and without telemetry.

Exodia is free and open source (MIT). See `LICENSE`, `TRADEMARK.md` and
`THIRD_PARTY_LICENSES.md`.

## Install and update

Ready-made macOS builds are the main installation path. Download an Exodia DMG
from [GitHub Releases](https://github.com/AbsoluteMode/exodia/releases), drag
**Exodia** into **Applications**, then open it. You do not need Xcode or an Apple
Developer account to use the app.

Choose the `Exodia-latest.dmg` asset from an Exodia release. Whytap-named assets
are historical builds. If no Exodia asset is listed yet, use the source-build
instructions under [Development](#development).

Community builds use a persistent, self-issued code-signing certificate, without Apple notarization. macOS may
warn on the first download; see [installation and permissions](docs/install.md).
Updates use the existing island **Update** button and verify the archive with
Exodia's Sparkle Ed25519 key, which is independent of Apple signing. An update
will not force a restart during a meeting recording, dictation or agent task.
A prepared download can also apply when you quit Exodia normally. **Later**
cancels the current installation; **Restart** applies it once work is finished.

Runtime: macOS 14.2 (Sonoma) or newer, on Apple Silicon or Intel. Exodia keeps
the original storage identities so the rename preserves settings, keys, notes
and agent memory.

Source and custom builds remain available; see [Development](#development).

## What runs where

| Feature | Route | Runs on |
|---|---|---|
| Dictation (Drop) | Your key (BYOK): Soniox, Deepgram, ElevenLabs, or a self-hosted OpenAI-compatible endpoint | the provider you chose, with your key |
| Smart cleanup of dictated text | OpenRouter with your key, or a custom OpenAI-compatible endpoint (Ollama, LM Studio, vLLM) | the endpoint you chose |
| Agent (Right Command) | OpenCode with your OpenRouter key and selected model | tools and memory on your Mac; inference at your selected provider |
| Meeting Notes | Your speech provider (Soniox labels speakers), then your LLM for the summary | the providers you chose |

Exodia no longer ships on-device speech or text models. If you used **Local**
before, Exodia does not switch you to a provider on its own: dictation opens
**Settings, Models** until you choose a speech provider, and recorded meetings
wait for both speech and an LLM. Fast uses no cleanup LLM. Smart requires the
LLM you chose: if it fails, Exodia keeps the transcript in memory and shows
Retry instead of silently inserting unprocessed text.

Keys you enter are stored in the macOS Keychain and sent only to the
provider you selected. Transcripts, notes and history are SQLite files under
`~/Library/Application Support/`.

## Set up in Settings

Exodia opens directly to the island. There is no onboarding wizard or account.
Open **Settings** from the island's hover controls:

1. In **Models**, select a speech provider and enter your API key. Save to
   check the connection and store the key in macOS Keychain.
2. Optionally configure OpenRouter or your own endpoint for text cleanup and
   meeting summaries.
3. In **Permissions**, grant Accessibility and Microphone for dictation.
   Meeting recording also needs System Audio Recording. Features may request
   a missing permission when you use them.

Hold Space in a text field, speak, then release. Settings remains available
for changing keys, permissions and models later. The Dynamic Island at the
top of the screen is the main UI; there is no menu bar item.

## Connect your agent

In **Settings, Agents**, install OpenCode or use an existing installation. Enter
an OpenRouter key, choose a model from the catalog or enter its exact ID, then
click **Save & connect**. OpenRouter charges your account for model requests.
The connection check itself does not submit a paid model request.

The agent can edit files and run tests by default. **Allow agent actions** can
be turned off in Settings. Its model configuration, memory and conversation
sessions stay local and are separated by active project.

## Local project knowledge

In **Settings, Projects**, add a project folder, index it and select the active
project. Keep project notes there too. The local search returns code and document
excerpts with file and line references for the agent's question; it does not
send the entire folder to a provider. Reindex explicitly after source changes.
There is no automatic live meeting copilot yet.

The catalog and text index stay on your Mac. Selected excerpts and notes can be
sent to the model provider you configure when you ask the agent a question.

## Hotkeys

| Action | Default |
|---|---|
| Dictate into the focused field | hold Space |
| Ask the agent by text / by voice | tap / hold Right Command |
| Google the selection or your voice | tap / hold Right Option |
| Record a meeting now | Option M |
| Hover buttons 1 to 5 | Option 1 to Option 5 |
| Close the agent answer | Escape |

Everything is remappable in **Settings, Hotkeys**. The Help window lists the
full set.

## Development

To customize Exodia, use a local checkout, Xcode 26 or newer and its Swift 6
macOS toolchain:

```bash
git clone https://github.com/AbsoluteMode/exodia.git
cd exodia
swift build
swift test
SIDEKEY_DEV_CODE_SIGN_IDENTITY=- ./scripts/dev-run.sh --run
```

Use `scripts/dev-run.sh` instead of `swift run`: it creates a proper app
bundle and preserves the beta bundle identity. The command above explicitly
uses ad-hoc signing, which can require granting permissions again after a rebuild.
For persistent grants, select your own local code-signing identity with
`SIDEKEY_DEV_CODE_SIGN_IDENTITY="Exodia Local"`; see the build guide for setup.
The maintainer's default requires the pinned community identity and fails if
its private key is unavailable. No private signing key is distributed with source.

See [build details](docs/build-and-release.md). Builds and tests run locally;
GitHub Actions is disabled. Ready-made releases
use the community DMG and signed Sparkle archive pipeline; no Apple Developer
account is required. Development builds use version `0.0.0-dev` / build `9999`
and do not accept binary-feed updates over your custom build. Update the source
with your agent, preserve your changes and rebuild instead.

Architecture notes live in `CLAUDE.md`, the product spec in `docs/SPEC.md`,
hotkey conventions in `docs/hotkey.md`, and the reasoning behind
non-obvious choices in `docs/decisions/`.

## Customize it with your agent

Use Claude Code, Codex, OpenCode or another harness in a local source checkout.
Start with `python3 scripts/customize.py discover --json`; the shared guides and
helpers cover source navigation, native build/run, focused tests, hover tools,
local data and custom monitoring dashboards. See [Customize Exodia](docs/customization/README.md).

## Contributing

See `CONTRIBUTING.md`. Bug reports and pull requests are welcome; proposals
that would require an Exodia-hosted service are out of scope by design.

## Security

See `SECURITY.md`. Report vulnerabilities to security@whytap.ai.
