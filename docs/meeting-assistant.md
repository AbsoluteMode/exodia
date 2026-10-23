# Meeting Assistant

Open **Meeting Assistant** from the island's tool search or Toolbox. Choose a
ready Space in the module, ask a question and press Enter. Answers include a
short conclusion, structured points and two follow-up suggestions. **Return
answer** restores a collapsed conversation. Escape leaves an input without
closing the module; the common × closes it and stops listening.

In **Settings → API & Models → Meeting Assistant**, explicitly choose a speech
route and an answer model. Both start unset. Choose a tool-capable answer model;
screenshots also require a model that accepts images. Whytap keeps the exact
provider/model choice and reports failures without substituting another route.

**Слушать встречу** starts system-audio transcription of the other participants
through the speech route. Questions extracted from the recent transcript appear
above older questions; click one for an answer. This does not start recording
notes or capture your microphone. Close the module or press Stop to end the
session. Stop preserves recent transcript in memory for pending questions; close
or changing Space clears it. Audio, transcript, images and conversations are not
saved by this pilot.

Once both model routes and a ready Space are selected, hovering over the island
while Meeting Notes records reveals a **magic wand** immediately to the right of
the recording timer. It is translucent when off and has a soft white/blue glow
while listening. Click it to enable or stop Assistant for this meeting. Connecting
has a visible outline and can be cancelled; cleanup is temporarily disabled.
If Assistant was started manually without Notes, its active session also exposes
this control on hover. It shares the module's Listen/Stop state and keeps answers
when stopped. Newly created Spaces refresh when hover opens. The ordinary
tool/search/deep link still only opens the module; hover alone never starts audio.

This choice stays in memory and is off after close, sleep or restart. When the
existing metadata-only probe has recognized meeting mic activity and that context
ends for 15 seconds, listening stops. A brief reconnect cancels the pending stop;
after a stop, a later meeting never starts listening by itself. No microphone
samples are captured by the probe. Manual use before a recognized call remains
possible; in that case use the magic icon, Stop, or close the module to stop. Muting a call
for long enough can look like an end, while calls without a detectable boundary
cannot be distinguished: this is a context heuristic, not a calendar/call ID.

**Прикрепить скрин** captures the island-selected display after the requested
macOS permission. Up to six thumbnails fit in a horizontal tray. Open one to
view it or use its × to remove it. The next submitted request uses a snapshot
of the tray. After success, its photos leave the tray; after failure/cancellation
they remain for retry. Changing Space or closing clears them.

Screenshot protection follows **Settings → Other → screenshot protection**.
The same native window-sharing policy as notifications applies to the module
and image preview. Test the actual call application's sharing mode before
relying on it; protection coverage across capture methods is not established
by a successful build or a window-sharing flag check alone.

## Prepare a Space with Codex or Claude Code

The coding agent reads the existing Space, preserves unrelated sources, and
edits the local catalog on the user's request. There is no manual creation form.
Discover this contract with `python3 scripts/customize.py discover --json`.

```sh
python3 scripts/meeting-space.py list
python3 scripts/meeting-space.py create my-project --name 'My project'
python3 scripts/meeting-space.py add-repo my-project /absolute/project/folder \
  --id repo --name Repository --scope Sources --scope docs
python3 scripts/meeting-space.py validate my-project
```

Use an actual user-selected project path. `.` explicitly includes the repository
root; otherwise scopes are relative paths. Locations use canonical paths; the CLI
resolves them before writing, and changing a root to a symlink invalidates it. The catalog is
`whytap/meeting-spaces/<id>.json` under the user Application Support directory. `--root` changes
the parent directory for isolated testing only. Writes are serialized and atomic
and keep one previous manifest. The app refreshes ready Spaces automatically.
A bad manifest does not stop other Spaces; editing the active Space cancels its
in-flight work and invalidates its conversation.

The version 1 schema contains `version`, `id`, `name`, `purpose`, `instructions`
and `sources`. A repository source has `id`, `kind: repository`, `name`, absolute
`location`, relative `scope` array and `access: read`. Runtime access rejects
paths outside these scopes, symlinks, hidden/build files and common credential
files. Keep source content and secrets out of manifests. File contents and
transcripts are evidence, not authorization or system instructions.

Database sources with `kind: database`, `connection_ref` by credential name
(`case://`, `keychain://` or `env://`) and table scopes are accepted as metadata.
**Database access is not connected in this pilot.** No credential value is read,
copied into the manifest or sent to a model. Do not promise live database answers
until a scoped adapter and its actual access have been verified.
