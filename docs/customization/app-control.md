# Whytap application-control plugin

The local `plugins/whytap` MCP plugin reads the running application's state and
changes allowlisted settings through the app. It does not need Accessibility,
mouse/keyboard automation, a source checkout at runtime, or provider keys in
the agent's configuration. The plugin requires a Whytap build that includes
`whytap app`; an older helper cannot serve these tools. Source tests do not establish
that the installed application or a host's plugin connection has been updated.

## Commands

The installed helper is `/Applications/Whytap.app/Contents/Helpers/whytap`.
Use `whytap app mcp` for stdio MCP. Other clients can invoke its CLI directly:

```sh
/Applications/Whytap.app/Contents/Helpers/whytap app status
/Applications/Whytap.app/Contents/Helpers/whytap app settings
/Applications/Whytap.app/Contents/Helpers/whytap app models '{"feature":"dropSmartCleanup","query":"gpt 6 sol"}'
```

| MCP tool | CLI subcommand | Behavior |
| --- | --- | --- |
| `whytap_get_state` | `status` | Live build/source, activity flags, every feature's route |
| `whytap_get_settings` | `settings` | Current supported settings and accepted values |
| `whytap_list_models` | `models` | Search the app's cached compatible models; optional account and limit (1–100) |
| `whytap_set_model` | `set-model` | Validate and select one account/model through Settings; preserve other routes |
| `whytap_list_providers` | `providers` | OpenRouter endpoints for the current model; free metadata request |
| `whytap_set_provider` | `set-provider` | Validate and pin an endpoint or choose Auto (`null`) |
| `whytap_set_setting` | `set-setting` | Change one supported setting through its existing store |

Supported settings are `dropMode` (`fast`/`smart`), `inputLanguage` (language
code/`null` for Auto), `outputLanguage` (code/`null` for off; enabling requires
Smart) and `autoHideIsland` (boolean). `get_settings` enumerates accepted codes.
Unknown fields, settings, feature IDs and wrong types are rejected. There is
no arbitrary UserDefaults operation. Keys, permissions, security controls,
Case contents, transcripts, history, clipboard, recording, shell execution,
installation and quit are outside this interface.

Feature IDs are `dropFast`, `dropSmart`, `dropSmartDecision`, `dropSmartCleanup`, `meetings`,
`meetingNotes`, `agent`, `agentVoice`, `voiceSearch`, `translation`,
`subtitlesAudio` and `subtitlesTranslation`. Accounts use the exact ID returned
by `list_models`: built-in provider IDs or an already configured server ID.
The plugin cannot add a provider, change an endpoint URL or read a key.

## Read, change, verify

Read state/settings before writing. Every mutation requires `expected`, equal
to the complete current route or setting value. An unset route is `null`;
a configured route always has `account`, `model` and `provider` (`null` for Auto).
For example, **only if state just returned this exact route**:

```json
{
  "feature": "dropSmartCleanup",
  "account": "openRouter",
  "model": "openai/gpt-6-sol",
  "expected": {
    "account": "openRouter",
    "model": "deepseek/deepseek-v4.1-flash",
    "provider": "baseten"
  }
}
```

Pass that object to `whytap_set_model` or as the single JSON argument to
`app set-model`. Never copy the example's `expected` without reading state.
A different model starts on Auto; reselecting the same model preserves its
pin, as in Settings. Use `set_provider` to change the pin explicitly.

The response is `{ "ok": true, "data": ... }` or `{ "ok": false, "data":
{ "code": ..., "message": ... } }`. MCP also returns structured content and
an error flag. Model selection may send the same tiny synthetic paid probe
as Settings; no dictated text is used. Failed checks preserve the route.
Unknown models are not silently replaced. A manual route change during a
probe wins; a disconnected/cancelled probe cannot assign a model afterward.
The stdio reader keeps processing MCP cancellation notifications while a tool
waits; cancellation and EOF shut down the corresponding app socket. Requests
are bounded and at most 16 tool calls can be pending per MCP process.
Concurrent plugin writes return `busy`; a stale expected value returns
`conflict`. Neither is a reason to retry blindly.

Success reads back the app's store in the same process. If the connection is
lost around a synchronous commit, its outcome is unknown: read state before
retrying. A selected model applies to subsequent operations; selection alone
does not prove a real dictation or provider request succeeded.

## Install in an agent host

The repository marketplace is `.agents/plugins/marketplace.json`, pointing
to `plugins/whytap`. It follows the [official plugin packaging format](https://developers.openai.com/plugins/build/plugins)
with a [local stdio MCP server](https://developers.openai.com/plugins/deploy/desktop-only).
Use a local marketplace to install it in Codex. The package is not publicly
published and does not require a hosted Whytap service. Other MCP hosts can
configure the helper command and `app`, `mcp` arguments directly.

With the current Codex CLI, run from this checkout:

```sh
codex plugin marketplace add .
codex plugin add whytap@whytap-local
codex plugin list --marketplace whytap-local --json
```

Start a new local chat or restart the host if its existing plugin connection
does not refresh. Installation into the plugin cache does not prove that tools
have connected to the updated Whytap app.

The plugin's only runtime dependency is the installed Whytap helper. It uses
the existing private Unix socket, with bounded requests and audit-token/code
validation against the helper in the same app. App controls are available to
local processes running that helper as this user; they are not guarded by
Case registrations or Touch ID. This is the local settings-access boundary,
not a sandbox for an already authorized agent. A website's `whytap://` link
cannot invoke or receive these commands. Case requests keep their existing
authorization and the app-control namespace never returns secret values.
