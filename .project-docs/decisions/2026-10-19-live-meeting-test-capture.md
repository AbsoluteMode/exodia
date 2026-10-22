---
id: live-meeting-test-capture-2026-10-19
type: decision
title: Collect causal live meeting evidence before evaluating assistance
summary: An opt-in Soniox stream preserves source audio, signal activity, online speaker labels and receipt times for testing.
status: confirmed
tags: [meetings, streaming, soniox, diarization, testing]
canonical_for: [live-meeting-test-capture]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: User requested preparation before the next day's calls, source timestamp mapping and low latency in the 2026-10-19 Meeting Assistant conversation.
    confirmed_at: 2026-10-19
  - type: user-confirmed
    reference: After inspecting build 1480, the user requested that this test mode not appear in the interface. Keep the internal opt-in and remove both Settings rows.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingLiveTestCapture.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingLiveTestMixer.swift
    confirmed_at: 2026-10-19
  - type: url
    reference: https://soniox.com/docs/api-reference/stt/websocket-api
    confirmed_at: 2026-10-19
related: [2026-10-20-meeting-source-noise-floor.md, 2026-10-22-no-retained-meeting-audio.md]
---

# Live meeting test capture

## Context

Saved post-meeting speaker labels cannot establish causal streaming attribution
or latency. The user wants incoming questions emphasized, their own questions
kept only as context, and preparation before the next day's real calls.

## Alternatives

- Completed transcript labels: rejected as live attribution evidence.
- Microphone-in-use: rejected because a call can keep the input open throughout.
- Replacing normal notes immediately: deferred until live evidence validates it.

## Decision

The internal local `sidekey.meetings.liveTestCapture` flag defaults to off
and requires Meeting Notes and Soniox selected for Meetings. It has no Settings
switch or test-files row, following the user's correction after build 1480.
Removing these controls preserves an explicitly enabled flag. It adds
one Soniox `stt-rt-v5` stream with diarization on and endpoint detection off,
alongside unchanged recorded-audio notes. This separate testing request does
not change the saved Meetings model/provider or generate suggestions.

An independent test mixer emits 100 ms frames after a 150 ms jitter allowance.
An absent input becomes silence; it never waits for the archival mixer's
five-second solo fallback. Source APIs expose sample arrays without hardware
timestamps, so placement uses callback-arrival estimates and sample continuity.

Private UUID directories under Application Support/Sidekey/meeting-assistant-tests
contain aligned mixed/mic/system PCM16 tracks, source RMS intervals, lifecycle
and late-input markers, and final Soniox tokens with timestamps, raw speaker ID,
estimated role and receipt time. A meeting-ID marker associates the normal
recording. Pauses and prerecord are excluded; reconnect starts a fresh session.

## Rationale

Signal activity is a cheap source hint, not VAD or identity proof. Exclusive
source word intervals accumulate at least 500 ms of consistent speaker anchors.
The [background-aware calibration](2026-10-20-meeting-source-noise-floor.md)
replaces the original fixed activity threshold and prevents repeated timestamps
and short source gaps from manufacturing anchors. Current overlap or an opposing
source remains unknown even for an anchored speaker. No future text or LLM naming
pass is used. The test tracks align to the test mix, not archival WAVs.

The queue is bounded to 100 frames. Overflow is explicit. A session stops at
two hours of test audio or a large scheduling gap. File/network failures never
stop normal notes. Stop drains in the background for up to eight seconds after
audio EOF. Credentials and provider error bodies are never persisted or logged.

## Sources

Implementation and official protocol references are listed above.

## Comments and objections

Echo can put remote speech on the microphone; people in one room can share it.
RMS cannot resolve those cases. Hardware-clock alignment, actual attribution
and complete latency remain real-call acceptance tests, especially on Bluetooth.

## Resolution

Prepare opt-in capture and synthetic lifecycle tests now. Validate on a real
call before evaluating question detection. No accuracy target is claimed.

## Consequences

Testing adds streaming ASR usage and retains private audio/text until deleted.
The maintainer's testing guide states this and documents the local folder.
Normal note deletion does not remove test bundles. Test opt-in is excluded from
backup so restore cannot enable it. Enable only for explicitly authorized tests.
Existing meeting permissions are sufficient; capture does not open another mic.

## Supersedes / superseded by

Narrowed to source dev builds by
[no retained meeting audio](2026-10-22-no-retained-meeting-audio.md).

## Update 2026-10-22

Capture is limited to source dev builds; packaged builds ignore the flag and
remove `meeting-assistant-tests` at launch. See
[no retained meeting audio](2026-10-22-no-retained-meeting-audio.md).
