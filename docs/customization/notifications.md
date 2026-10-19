# Custom notifications

Notify restores the compact dark notification pill to the **left of the island**,
with its logo, title, body, animated color wash and countdown. Hover pauses the
countdown; clicking opens the supplied link, or dismisses an event without a link.
Notify has persistent history and source controls. It is available from hover
search and Settings → Toolbox; saved tool layouts are preserved.

**Settings → Notifications** lists every connected source, its logo and current
status. Each source has its own on/off switch. Turning it off stops its script
and notifications immediately, while keeping its configuration and event history;
the switch remains off after restarting Whytap. Agent-added sources appear
automatically without reopening Settings.

A coding agent can connect a source without rebuilding Whytap. Ask the agent for
the exact events you want; it requests the access and filters needed for that
source, then installs a private local script and manifest. This does not authorize
sending messages to other people. Whytap itself has no notification server or
provider-specific account setup.

## Local contract

The runtime publishes a complete guide in `notifications/README.md` inside
the bundle ID’s Application Support directory.

`<bundle-id>` is `com.rootwise.sidekey` for production and
`com.rootwise.sidekey.beta` for beta. The app's agent prompt points to the actual
resolved directory on each turn, including resumed sessions. Any local coding
agent can read that guide. Source implementation:
`Sources/Sidekey/Notifications/NotifySetupGuide.swift`.

Write `sources/<id>.json` atomically, mode 600. Required fields are `id`, `name`,
and `command` (an argv array whose first element is an absolute executable path).
Optional fields: `enabled` (true), `intervalSeconds` (5–86400), `tint` (`#RRGGBB`),
`logo`, `duration` (2–60 seconds, default 8). There are at most 16 sources.

```json
{
  "id": "example",
  "name": "Example",
  "command": ["/bin/zsh", "/absolute/path/to/example.zsh"],
  "intervalSeconds": 30,
  "tint": "#299FD6",
  "logo": "paperplane.fill"
}
```

The script writes one flushed UTF-8 JSON object per stdout line:

```json
{"id":"event-123","title":"Message from Alex","body":"The build is ready","tint":"#299FD6","logo":"paperplane.fill","duration":8,"link":"https://example.com/message/123"}
```

`title` is required (up to 200 characters); optional `body` has up to 8000.
Presentation fields override the source defaults. A stable event `id` is scoped
to the source and deduplicated across launches while retained in history (500
events). Scripts should also persist upstream cursors privately to avoid replaying
a backlog after reconnect. No historical pills replay on app launch.

A `logo` names an SF Symbol or an image in `logos/`, without its extension.
PNG, JPEG and PDF are supported up to 2 MiB; remote logo URLs and paths are not.
History stores each event's actual presentation. A link is optional and opens
only on a user click; supported schemes are http(s), tg, slack, linear, github
and mailto. A notification without a link simply dismisses.

## Lifetime, failures and privacy

Scripts run while Whytap is open, even when the drawer is closed. They pause on
system sleep and restart on wake. Disabling/removing a source or quitting Whytap
stops its process group, including helpers. The same happens within about a
second when Whytap is killed or crashes: a small guard process leads the group
and ends it when the app's end of its stdin closes. Scripts get /dev/null as
stdin. Do not daemonize or install a separate
LaunchAgent. Scripts that intentionally detach from their process group are
outside this cooperative contract. No shell interpolation is performed by Whytap.

A continuous script should stay alive. Clean exit restarts after 5 seconds unless
`intervalSeconds` is supplied; in that case a polling pass repeats after that
delay. Errors retry with backoff up to 60 seconds. Each source can deliver up to
10 events/second; a line is limited to 64 KiB and worker output to 1 MiB/second.
The visible queue holds 32 events; excess accepted events remain in history.

Store credentials in Keychain or the user's chosen credential manager. The
manifest, arguments and events must never contain credentials. Whytap does not
log script output and discards stderr, showing only generic failures/exit status
in Notify → Sources. Scripts are local programs running with the user's ordinary
permissions; this is not a filesystem sandbox.

Use a synthetic, uniquely identified event for setup verification, then confirm
its exact `<source-id>:<event-id>` in `history.json`. A running process does not
prove upstream connectivity. Never claim a Telegram connection based only on a
synthetic fixture. Removing a source preserves its script files, credentials and
notification history. Unreadable existing history is preserved rather than reset.

Notify workers receive `WHYTAP_NOTIFY_SOURCE` and `WHYTAP_NOTIFY_DIRECTORY`.
The original `EXODIA_NOTIFY_SOURCE` and `EXODIA_NOTIFY_DIRECTORY` aliases remain
available to existing local scripts.
