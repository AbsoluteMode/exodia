# Meeting Assistant: an explicit session switch

On 2026-10-24 the user requested a hover switch to force Meeting Assistant on or
off for one meeting, while the already reviewed pilot is promoted independently.

Expose a compact full-row toggle below hover search after both routes and a
ready Space are configured. Startup preparation reads metadata only. Show-only
tool/search/link activation stays unchanged. The row and module Listen/Stop use
one model; stop releases audio and cancels extraction without losing answers.
Pending starts are cancellable and revalidate the catalog before opening audio.
Space changes, close, sleep and provider failures keep their existing stop rules.

The choice is deliberately in-memory. Reopening the app or detecting another
meeting never auto-enables capture. While explicitly listening, reuse a separate
metadata-only MeetingContextActiveProbe, independent of Meeting Notes. After a
recognized context has ended for 15 seconds, stop; a brief reconnect cancels the
stop. Do not interpret an initial false sample as an end of a manual session.
This heuristic sees recognized app/browser mic activity, not a unique call ID:
long mute may stop a call and seamless call switches may have no visible boundary.
An unrecognized manual session must be stopped explicitly. No microphone content,
calendar data, call URLs or additional model requests are used for this control.

The row has its own first-mouse region available with both tool tiles and search
results. It must not dispatch the show-only tool or activate an unrelated result.
Control geometry and the native hit band grow together, with visible hover,
pressed, keyboard-focus, connecting and disabled-cleanup states. Native offscreen
fixtures and fake probes/providers verify these transitions; real call behavior
remains installed acceptance.
