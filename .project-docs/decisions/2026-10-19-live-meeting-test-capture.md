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
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingLiveTestCapture.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingLiveTestMixer.swift
    confirmed_at: 2026-10-19
  - type: url
    reference: https://soniox.com/docs/api-reference/stt/websocket-api
    confirmed_at: 2026-10-19
related: []
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

Settings → Other exposes **Meeting Assistant test capture**, off by default
and available only with Meeting Notes and Soniox selected for Meetings. It adds
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
Overlap, silence and conflicting anchors remain unknown. No future text or
LLM naming pass is used. The test tracks align to the test mix, not archival WAVs.

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
Settings states this and opens the folder. Normal note deletion does not remove
test bundles. Test opt-in is excluded from backup so restore cannot enable it.
Existing meeting permissions are sufficient; capture does not open another mic.

## Supersedes / superseded by

None.
