# Meeting Assistant pilot

On 2026-10-23 the user approved the native Meeting Assistant design and chose
a live pilot inside Whytap. The earlier Meeting Lab remains a visual reference.
Its mock responses, debug command files and autoplay are not application code.

The pilot has a passive right-hand module with a Space picker, plain question
input, up to six removable screenshot thumbnails, five recent questions and
twenty answered roots. Answers have a conclusion, numbered points and two
continuations. Collapsing an answer preserves its conversation. Escape in an
editor releases focus; only the common close control closes the module.

Spaces are created or edited by a coding agent on the user's request through
`scripts/meeting-space.py`; the human only selects ready Spaces in Whytap.
Runtime reads validate each manifest and use descriptor-relative read-only
repository tools. A working directory alone is not a data boundary. Symlinks,
path traversal, hidden files and credential filenames are excluded. The normal
Agent's shell, write, arbitrary-path, web and Case tools are not included.
Database declarations are retained as metadata and are explicitly unavailable
until a scoped database adapter exists; credentials are not resolved.

Meeting Assistant and Meeting Assistant audio are separate, initially unset
routes in API & Models. No routes are copied from Agent, Notes or Subtitles.
The answer loop shares the native provider transport, not the ordinary Agent's
workspace, system prompt, disk history or tools. Costs retain the feature ID.
The configured model must support tool calls; attached images require vision.

Listening is explicit and captures only system audio from other participants.
It does not start Meeting Notes, use the microphone or retain audio on disk.
Provider finals stay in a bounded in-memory rolling context. A bounded periodic
analysis extracts questions; answers run only on the user's click or submission.
Stopping, closing, sleep or changing Space cancels work. Provider failures stop
listening visibly, with no retry or model/provider substitution. Malformed question
JSON is a recoverable parsing issue: keep listening, show a warning, and analyze
only after fresh transcript arrives; do not retry the same paid request. Stop
retains recent evidence for pending questions; close or Space changes clear it.

Screenshots are explicit, exclude Whytap's own application windows, remain in
RAM and belong to the submitted request snapshot. Successful delivery removes
only its submitted thumbnails; failed/cancelled requests retain them for retry.
Later questions do not silently resend successfully consumed photos. Switching
Space or closing clears them. Window sharing protection follows the existing
Other setting through the same callback used by notification windows.

Safe tests use fake providers and temporary catalogs. Real call latency,
question quality, native focus, provider vision and screen-sharing exclusion
remain installed acceptance, separately from source/build readiness.


Compatibility: the new usage feature IDs are forward additions to the existing
usage store. A retained older binary does not recognize those IDs after the
pilot first runs. The builder must account for Costs/usage-backup compatibility
before a binary rollback; installation itself does not rewrite old usage rows.
No user usage rows are deleted or rewritten to conceal that limitation.
