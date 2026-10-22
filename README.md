# Whytap

Voice input and a voice-driven agent for macOS. Bring your own API keys
(BYOK) or your own OpenAI-compatible endpoint.

Hold **Space** in any text field, speak, release: the transcript is pasted
where the cursor is. Tap **Right Command** to ask Whytap Agent
by text, hold it to ask by voice. Choose its model through OpenRouter. Let
Whytap notices your meetings and turn them into notes. All of it without an
account, without Whytap servers and without telemetry.

Whytap is free and open source (MIT). See `LICENSE`, `TRADEMARK.md` and
`THIRD_PARTY_LICENSES.md`.

## Install and update

Ready-made macOS builds are the main installation path. Download a Whytap DMG
from [GitHub Releases](https://github.com/AbsoluteMode/whytap/releases), drag
**Whytap** into **Applications**, then open it. You do not need Xcode or an Apple
Developer account to use the app.

Choose `Whytap-latest.dmg` when available. During the rename, the latest
published package may still be `Exodia-latest.dmg` and contain **Exodia**; it is
the same application. Use the app name shown in that disk image. Existing
Exodia release links continue to redirect to this repository.

Community builds are signed with the Developer ID certificate of Whytap's Apple
team and notarized by Apple; macOS can show its standard confirmation for an app
downloaded from the internet. See [installation and permissions](docs/install.md).
The stable team identity preserves privacy and Keychain grants on subsequent
same-team updates. The first upgrade from an older community-signed build may
ask for those permissions again.
Updates use the existing island **Update** button and verify the archive with
Whytap's Sparkle Ed25519 key, which is independent of Apple signing. An update
will not force a restart during a meeting recording, dictation or agent task.
A prepared download can also apply when you quit Whytap normally. **Later**
cancels the current installation; **Restart** applies it once work is finished.

Runtime: macOS 14.2 (Sonoma) or newer, on Apple Silicon or Intel. Whytap keeps
the original storage identities so the rename preserves settings, keys, notes
and agent memory.

Source and custom builds remain available; see [Development](#development).

## What runs where

| Feature | Route | Runs on |
|---|---|---|
| Dictation (Drop) | Your key (BYOK): Soniox, Deepgram, ElevenLabs, or a self-hosted OpenAI-compatible endpoint | the provider you chose, with your key |
| Smart cleanup of dictated text | OpenRouter with your key, or a custom OpenAI-compatible endpoint (Ollama, LM Studio, vLLM) | the endpoint you chose |
| Agent (Right Command) | Built-in Whytap Agent with your OpenRouter, OpenAI or Anthropic model | tools and memory on your Mac; inference at your selected provider |
| Meeting Notes | Your speech provider (Soniox labels speakers), then your LLM for the summary | the providers you chose |

Whytap no longer ships on-device speech or text models. If you used **Local**
before, Whytap does not switch you to a provider on its own: dictation opens
**Settings, API & Models** until you choose a speech model, and recorded meetings
wait for both speech and an LLM. Fast uses no cleanup LLM. Smart requires the
LLM you chose: if it fails, Whytap keeps the transcript in memory and shows
Retry instead of silently inserting unprocessed text.

Keys you enter are stored in the macOS Keychain and sent only to the
provider you selected for that feature. Transcripts, notes and history are SQLite files under
`~/Library/Application Support/`.

## Set up in Settings

Whytap opens directly to the island. There is no onboarding wizard or account.
Open **Settings** from the island's hover controls:

1. In **API & Models**, click **Add key** under **API keys**, pick a provider
   (Soniox, Deepgram, ElevenLabs, OpenRouter, Anthropic for the agent, or your
   own OpenAI-compatible server) and paste its key. Whytap checks it with a
   free request and stores it in macOS Keychain. A dot on each provider chip
   shows whether the key works.
2. Under **Models**, give each feature a model: Drop Fast, Drop Smart, Drop
   Smart cleanup, Meetings, Meeting notes, Agent, Agent voice, Voice search,
   Translation and Subtitles audio.
   After you add a key, **Set up** offers to assign it to the features it can
   serve; nothing is assigned until you choose. A model that is not in Whytap's
   built-in list is checked with a tiny synthetic request when you pick it.
3. In **Permissions**, grant Accessibility and Microphone for dictation.
   Meeting recording also needs System Audio Recording. Features may request
   a missing permission when you use them.

Hold Space in a text field, speak, then release. Settings remains available
for changing keys, permissions and models later. The Dynamic Island at the
top of the screen is the main UI; there is no menu bar item.

## Connect your agent

Choose the **Agent** model and add its OpenRouter, OpenAI or Anthropic key in
**Settings → API & Models**, then click **Connect** in **Agents**. The agent is
built into Whytap. Connect prepares the local workspace and checks that a key
is present; model requests are billed by your provider.

For web search, add a **Tavily** key in **Settings → Agents → Web search**.
Saving checks the key without running a search. Search queries go to Tavily;
results go to your selected model.

The agent can edit files and run commands by default. Turn off **Allow file
edits and commands** to block both. Its dedicated folder is
`~/Library/Application Support/whytap/agent`, also available through **Open
folder**. AGENTS.md keeps memory; recent text context resumes for 15 minutes,
up to six pairs/12,000 characters. Screenshots and tool output stay out of that
new conversation file. Approval modes are a later phase.

## Custom notifications

Notify shows compact notifications to the left of the island and keeps their
history, colors and logos. Ask your coding agent to connect the source and
filters you want; Whytap runs its local script only while the app is open.
Find **Notify** in hover search or add it in **Settings → Toolbox**.
[Setup and script contract](docs/customization/notifications.md).

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

To customize Whytap, use a local checkout, Xcode 26 or newer and its Swift 6
macOS toolchain:

```bash
git clone https://github.com/AbsoluteMode/whytap.git
cd whytap
swift build
swift test
./scripts/dev-run.sh --run
```

Use `scripts/dev-run.sh` instead of `swift run`: it creates a proper app
bundle at a stable path and preserves the bundle identity. With the existing
local signing identity, permission grants can survive rebuilds. An ad-hoc
rebuild may require granting permissions again in macOS Settings.

See [build details](docs/build-and-release.md). Builds and tests run locally;
GitHub Actions is disabled. Ready-made releases
use the community DMG and signed Sparkle archive pipeline; building from source
needs no Apple Developer account. Development builds use version `0.0.0-dev` / build `9999`
and do not accept binary-feed updates over your custom build. Update the source
with your agent, preserve your changes and rebuild instead.

Architecture notes live in `CLAUDE.md`, the product spec in `docs/SPEC.md`,
hotkey conventions in `docs/hotkey.md`, and the reasoning behind
non-obvious choices in `docs/decisions/`.

## Customize it with your agent

Use Claude Code, Codex, OpenCode or another harness in a local source checkout.
Start with `python3 scripts/customize.py discover --json`; the shared guides and
helpers cover source navigation, native build/run, focused tests, hover tools,
local data and custom monitoring dashboards. See [Customize Whytap](docs/customization/README.md).

## Contributing

See `CONTRIBUTING.md`. Bug reports and pull requests are welcome; proposals
that would require a Whytap-hosted service are out of scope by design.

## Security

See `SECURITY.md`. Report vulnerabilities to security@whytap.ai.

### Translation

Use **Translate** or **Subtitles** in the island’s tool search. Translate text
with automatic RU↔EN direction or choose a target language; read floating
subtitles for system audio without opening the microphone. Choose the
**Translation** and **Subtitles audio** routes in API & Models first. Both
tools can be pinned in Toolbox or assigned shortcuts. [Usage and privacy](docs/translation.md).
