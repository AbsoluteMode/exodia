# Meeting Assistant: an explicit session switch

On 2026-10-24 the user requested a hover switch to force Meeting Assistant on or
off for one meeting, while the already reviewed pilot is promoted independently.

The user refined the control to a magic icon immediately to the right of the
recording timer, visible on island hover. It is translucent off, softly glowing
while listening, outlined while connecting, and disabled during audio cleanup.
Reveal it once routes and a ready Space are configured and Notes is recording;
keep it available during an explicitly active Assistant session without Notes.
The fixed 28pt target occupies a 36pt extension of the existing black island;
it never displaces the timer or grows the drawer. Other inline hover panels and
higher-priority agent/nudge/approval surfaces hide it. Tool/search/link activation
stays show-only. The icon and module Listen/Stop share one model; stop releases
audio and extraction without losing answers. Pending starts are cancellable and
revalidate the catalog before audio. Startup/hover preparation reads metadata
only. Space changes, close, sleep and provider failures keep existing stop rules.

The choice is deliberately in-memory. Reopening the app or detecting another
meeting never auto-enables capture. While explicitly listening, reuse a separate
metadata-only MeetingContextActiveProbe, independent of Meeting Notes. After a
recognized context has ended for 15 seconds, stop; a brief reconnect cancels the
stop. Do not interpret an initial false sample as an end of a manual session.
This heuristic sees recognized app/browser mic activity, not a unique call ID:
long mute may stop a call and seamless call switches may have no visible boundary.
An unrecognized manual session must be stopped explicitly. No microphone content,
calendar data, call URLs or additional model requests are used for this control.

The icon has its own measured first-mouse target independent of tool/search rows.
The visible black extension and native mouse region use the same 36pt geometry;
both disappear on collapse. Hover/press/focus feedback covers the full 28pt target,
and disabled cleanup has no active highlight. State changes cancel only an old
icon press, preserving unrelated held tool clicks. Idle stop never invents cleanup;
repeated active stop keeps the real release gate. The 3.2s breathing halo changes
only light intensity; reduced motion uses a static glow and pauses frame updates.
Native offscreen fixtures, pure geometry and fake probes/providers verify these
contracts. Physical pointer/keyboard/VoiceOver, call and sharing remain installed
acceptance. The probe is independent from Meeting Notes and captures no audio.
