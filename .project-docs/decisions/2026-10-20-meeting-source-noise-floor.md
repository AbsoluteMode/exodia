---
id: meeting-source-noise-floor-2026-10-20
type: decision
title: Separate microphone background from speaker evidence and limit capture gain
summary: Calibrate source activity independently and preserve quiet microphone boost without clipping loud buffers.
status: confirmed
tags: [meetings, audio, microphone, diarization, testing]
canonical_for: [meeting-source-activity-calibration, meeting-microphone-gain]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 the user confirmed that the principal voice in the active test was the remote participant despite its local label, authorized tuning during the call, and requested checking the older quiet-microphone issue against official guidance.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingSpeakerSourceMapper.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Meetings/MicSampleGain.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Tests/SidekeyTests/Meetings/MeetingSpeakerSourceMapperTests.swift
    confirmed_at: 2026-10-20
  - type: url
    reference: https://developer.apple.com/documentation/avfaudio/avaudioinputnode/isvoiceprocessingagcenabled
    confirmed_at: 2026-10-20
  - type: url
    reference: https://soniox.com/docs/stt/concepts/speaker-diarization
    confirmed_at: 2026-10-20
related: [2026-10-19-live-meeting-test-capture.md]
---

# Background-aware source evidence

## Context

A fixed RMS threshold treated amplified microphone background as local signal.
Remote speech gaps could then accumulate local evidence for a remote speaker.
Capture already applied a fourfold microphone boost, so increasing gain again
would not address the source-label error. Loud microphone buffers could also
hit its hard clamp.

## Decision

The internal test writer calibrates each source separately on captured 100ms
frames, before processing ASR tokens. Twenty frames establish initial readiness.
The activity threshold is the greater of 0.003 and three times the lower quintile
of up to 100 background observations. Once calibrated, foreground frames do not
raise that source's background estimate. Pause/resume restarts calibration.
Thresholds and readiness are saved alongside raw RMS values for diagnosis.

Speaker anchors require 500ms of unique token time supported by an exclusive
source across a window extending 100ms to either side. Repeated subword times
cannot accumulate duplicate evidence. A known speaker cannot override current
overlap or evidence for the opposite source. Existing audio and tokens can be
replayed locally; they need no new provider request and are never rewritten.

Meeting microphone capture retains the existing maximum fourfold boost. A
stateful per-buffer peak limiter reduces gain before output exceeds 0.95, then
recovers toward the maximum with a 500ms release. It resets with the converter
and changes neither hardware input volume nor other applications' audio.

## Alternatives

- Raising one fixed threshold: rejected because microphone gains and background
  levels differ, and quiet speech must remain detectable.
- Increasing microphone gain: rejected because the boost already exists and
  loud buffers need more headroom.
- Enabling platform voice processing immediately: deferred. Apple's voice
  processing supports AGC, but this independent capture graph does not currently
  supply a playback reference. Echo cancellation and output/route interactions
  need separate device acceptance rather than a speculative live-call change.
- Faster Soniox finalization: unchanged. The provider documents its diarization
  accuracy tradeoff; this fix changes local source evidence only.

## Verification and limitations

Synthetic regressions cover microphone background, quiet and sustained speech,
source gaps, overlap, repeated timestamps, invalid input and gain attack/release.
Private causal replay uses only the already captured frames and received tokens;
it is diagnostic evidence, not an independent accuracy benchmark. No private
audio, text, file identifiers or replay artifacts belong in the repository.

Signal activity remains a heuristic. Shared microphones, acoustic echo, abrupt
noise changes and approximate source clocks can still require unknown labels.
The limiter cannot repair clipping in previously captured files. Fresh-device
and next-call acceptance remain necessary after safe installation; an active
recording must not be interrupted to install this change.
