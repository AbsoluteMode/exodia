# First Escape belongs only to the visible Agent answer

Date: 2026-10-23.

The user reported that closing a Whytap answer with Escape nearly cancelled
inference in the application underneath. They explicitly requested consumption
of that first Escape, scoped to the answer so additional Escapes are not taken.
This supersedes the double-action policy in
[the passive-monitor decision](2026-07-02-escape-close-passive-monitor.md).

`AgentController` arms `EscapeCloseEventMonitor` only for
`IslandAgentFlowStore.answerPanelVisible`, independent of app activation.
Agent recording, composing, acting without answer content and idle remain
outside this interceptor. A visible answer also yields during any non-idle
Drop phase, Screenshot editing/capture, Case approval and Settings shortcut
recording. Their existing Escape handling keeps priority; the answer is not
dismissed. If it is still visible after that interaction ends, ownership resumes. No focus change, global Carbon Escape registration or new
preference is introduced.

The answer tap is appended after existing session taps. Drop/Case head taps
therefore retain cancellation priority even before their main-thread activity
flags arrive. The tap host's default placement stays unchanged for other callers.

A session event tap on the existing dedicated tap-thread host consumes one
fresh bare Escape key-down. Its repeats and key-up remain consumed after the
answer closes, then the tap is removed. The next separate physical press
passes through. Modified Escape and other keys pass unchanged. A key held
before the answer appears cannot close it through autorepeat. New answer
generations invalidate queued closes from older answers.

Click dismissal removes the tap immediately unless it is still draining an
already consumed press. During that drain only, a 100 ms check of the HID
Escape state recovers a missing key-up; a new non-repeat press also clears a
stale latch. The hardware table is upstream of session event consumption
([Apple event-state documentation](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid)).
The callback does no UI work, network, file access or logging of input.
It queues one close on the main thread and returns the consume decision first.

Unavailable/revoked Accessibility interception fails open for the user's app:
the answer's close button and configured close shortcut remain available.
There is no passive fallback that would close the answer and also cancel the
underlying app. Re-enabling a disabled tap is bounded to three consecutive
attempts with Accessibility; unused/failed sessions are disposed. The real
driver requires a packaged app host so SwiftPM tests cannot install an active
global filter.

Verification uses pure filter cases, a fake tap with unposted events, and the
controller's existing answer-visibility lifecycle fixtures. Tests cover first
press versus next press, held repeats, modified/preheld Escape, missing key-up,
external dismissal, stale queued close, driver failure, permission loss and
controller release, Drop cancellation without transcription, and suspension/
restoration around capture and shortcut recording. Live physical input/foreground-app acceptance remains a
separate installed check; tests do not create a real tap or cancel inference.
