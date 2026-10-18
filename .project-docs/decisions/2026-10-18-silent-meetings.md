---
id: silent-meetings-2026-10-18
type: decision
title: A meeting without speech is finished, not failed
summary: A completed Soniox job with no recognised speech stores a "No speech detected" note and releases the staged audio instead of failing and retrying forever.
status: confirmed
tags: [meetings, soniox, recovery]
canonical_for: [silent-meeting-outcome]
verified_at: 2026-10-18
sources:
  - type: repository
    reference: Sources/Sidekey/Meetings/SonioxMeetingTranscriber.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingBYOKProcessor.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/Meetings/MeetingBYOKProcessorTests.swift
    confirmed_at: 2026-10-18
related: [2026-09-07-soniox-meeting-files.md]
---

# Silent meetings

## Context

Meeting Notes kept producing failed meetings with "Soniox returned no
speaker-attributed transcript. The audio is saved for retry." In 24 hours the
local log had 12 such failures and 2 Keychain failures (OSStatus -25320,
errSecInDarkWake), all from two recordings of 3-4 seconds. Their audio was
the room noise floor: about -55 dBFS RMS, peak -30 dBFS, while speech is
about -30 to -20 dBFS RMS.

The completed Soniox job contained no speech, so the attribution check threw.
The meeting was marked failed and its manifest stayed staged. Launch recovery
runs twice per launch and again on every full wake, including dark wake. Each
retry read the same completed job, failed the same way and never deleted the
remote job or file.

## Decision

A completed job whose transcript has no text and no tokens with text, apart
from end markers, decodes to an empty result. The checkpoint stores that
result like any transcript, and the remote job and file are deleted. The
BYOK processor then stores a plain "No speech detected" note with an empty
transcript, without calling the LLM, and removes the staging directory
(audio, manifest and checkpoint).

Speech without speaker labels remains a processing error, as decided in
2026-09-07-soniox-meeting-files.md.

## Rationale

Silence is a final result, not an outage. The same audio returns the same
empty transcript on every retry, the same rule Drop uses: an empty batch
means silence. Keeping silence retryable produced repeated log errors and
red failed rows, which the UI cannot delete. It also caused Keychain reads
during dark wake and leaked Soniox resources. The note keeps the recording
visible, so a long recording made with a muted microphone does not disappear
without explanation.

## Verification

Unit tests cover:

- silence payloads, including a payload that has only an end marker, decode
  to an empty result;
- a completed silent job deletes the remote file and job, and its checkpoint
  is reused with no network requests;
- the processor stores the note without an LLM request, marks it ready
  without a failure reason, and removes the staged audio and manifest;
- speech without speaker labels still throws.

All new tests failed before the change with the production error message.
The full suite then passed: 2,950 tests, 8 skipped, 0 failures. The audio
of both staged recordings was measured locally.

Not verified:

- the actual Soniox response bodies for those two jobs. They were not fetched,
  so the Keychain key was never read outside the app.
- the installed app recovering both recordings after an update.

## Alternatives

- Keep the failure but stop retrying. Rejected: this leaves a permanent red
  row that the UI cannot delete, and its "recording is saved" reason would be
  false after cleanup.
- Discard silent recordings entirely. Rejected: a long meeting recorded with
  a muted microphone would vanish without explanation.
- Delete remote resources on every decode failure. Rejected: each launch and
  wake would then upload the recording again and pay for another
  transcription of unattributed speech.
- Apply the same rule to the local pipeline and the realtime BYOK adapters.
  Not done: neither is part of the observed failure. A realtime adapter can
  also end empty after an aborted stream, so its empty result does not prove
  silence.

2026-10-18, PR https://github.com/AbsoluteMode/exodia/pull/16.
