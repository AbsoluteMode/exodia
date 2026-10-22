---
id: meeting-recovery-dark-wake-2026-10-18
type: decision
title: A Keychain prompt that cannot be shown defers a meeting, it does not fail it
summary: When a BYOK key read for meeting processing fails with errSecInDarkWake, the coordinator keeps the meeting staged without a failure event and restores its earlier failure reason; the full-wake or next-launch recovery pass processes it.
status: confirmed
tags: [meetings, recovery, keychain, sleep]
canonical_for: [meeting-recovery-dark-wake]
verified_at: 2026-10-18
sources:
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsCoordinator.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsStore.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/Meetings/MeetingsCoordinatorTests.swift
    confirmed_at: 2026-10-18
related: [2026-10-18-silent-meetings.md, 2026-10-22-no-retained-meeting-audio.md]
---

# Meeting recovery in dark wake

## Context

Launch recovery dispatches every staged meeting again. It runs twice per
launch, the passes chained through `launchRecoveryTask`, and once more from
`startReady()` after a `.full` wake. The BYOK processor reads the user's keys
from the Keychain: the OpenRouter key in `DirectLLMRouteResolver` and the
Soniox key in `MeetingBYOKProcessor`.

Each community build has a new ad-hoc signature, so the legacy ACL of an
existing Keychain item asks the user again. When macOS cannot show that
prompt, the read fails with OSStatus -25320 (`errSecInDarkWake`). On
2026-10-18 a launch had waited on such a prompt since the previous evening.
Closing the lid at 06:24:39 dismissed it, the launch continued, and both
recovery passes for one meeting got -25320 within a second. The coordinator
handled it like any processing error: it broadcast `.meetingFailed` and
replaced the meeting's real failure reason with "Keychain error: OSStatus
-25320". After the full wake at 06:32:16 the `.full` rearm ran recovery
again, the user allowed both prompts and the real cause appeared: a silent
recording, fixed in PR #16.

In that log, recovery did not run during the Power Nap dark wakes
themselves. The error came from the launch pass while the system was going
to sleep.

## Decision

`MeetingsCoordinator.dispatchFinalizedForProcessing` handles
`KeychainError.unhandledError(errSecInDarkWake)` from the direct processor
separately:

- no `.meetingFailed` event;
- the manifest and audio stay staged;
- a meeting that was failed before this attempt gets its status and failure
  reason back. `MeetingsStore.progressState(id:)` reads them before the
  attempt resets the row to transcribing;
- a meeting without an earlier failure stays transcribing until the next
  pass.

The next pass is the existing one: `startReady()` after a `.full` wake, or
the next launch. No trigger was added and the chained launch passes are
unchanged. The log line contains only the meeting ID.

## Rationale

The error describes the Keychain UI at that moment, not the meeting.
Recording it as the meeting's failure hides the real cause and shows a
failure for a meeting that will be processed later. Reacting to the status
code covers the observed case, which a wake-state gate would miss: the
display was already off but the system had not posted willSleep yet when the
launch pass ran. The change stays in the coordinator, so the processors and
the AppDelegate wake path are untouched.

## Verification

Two coordinator tests:

- recovery in dark wake keeps an earlier failure ("BYOK transcription
  failed: simulated 503") and the manifest and emits no event; the next
  `resumePendingProcessingOnLaunch()`, the call `startReady()` makes after a
  full wake, stores the meeting as ready without a failure reason;
- a fresh dispatch in dark wake emits no event, leaves the row transcribing
  without a failure reason and keeps the manifest.

Both failed before the change: the reason became "Keychain error: OSStatus
-25320" and `.meetingFailed` was broadcast. The full suite then passed:
2,959 tests, 8 skipped, 0 failures.

Not verified:

- a real lid close or dark wake with the installed app. The timeline comes
  from the unified log of the app process, securityd and `pmset -g log`;
- the AppDelegate wake path itself. The test calls the coordinator entry
  point that `startReady()` uses.

## Alternatives

- Postpone recovery until a full wake. Rejected: it misses a launch during
  lid close, the observed case, and needs a power-state gate in the
  AppDelegate path.
- Also defer on `errSecInteractionNotAllowed` (-25308). Not done: not
  observed, and a locked keychain can last much longer than a dark wake.
- Mark the meeting failed with a friendlier message. Rejected: it still
  replaces the real reason and shows a failure for a meeting that will be
  processed.
- Retry on a timer in the coordinator. Rejected: the full-wake rearm already
  reruns recovery; a timer would only add attempts while no prompt can be
  shown.

Found during the investigation, not changed here:

- `MeetingBYOKProcessor.makeTranscriptionAdapter` reads non-Soniox keys with
  `try?`, so -25320 there becomes "BYOK transcription key is missing." and is
  still recorded as a failure.
- A Keychain prompt at launch kept the main thread waiting for 11 h 23 min
  before the launch finished; the Soniox key is also read on the main actor.
- A `.soft` wake (screens wake without a preceding willSleep) does not rerun
  recovery.

2026-10-18, PR https://github.com/AbsoluteMode/exodia/pull/21.
