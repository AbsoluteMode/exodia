---
id: whytap-meeting-continuations
type: decision
title: Immediate meeting notes and three-minute continuations
summary: Process each completed call immediately and append a confirmed continuation to the existing meeting without reprocessing earlier audio.
status: confirmed
tags: [meetings, reconnect, notes, recovery, editing]
canonical_for: [meeting-continuations]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 the user requested immediate notes, a three-minute Reconnect window and an Updating status while the continued call supplements the previous meeting.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsCoordinator.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsStore.swift
    confirmed_at: 2026-10-20
related: [../project.md]
---

# Immediate notes and confirmed continuations

## Context

Previously an auto-ended recording waited 45 seconds before processing. The
older three-minute window delayed all notes, even when the meeting had simply
ended. The user requested that processing and the Reconnect choice be independent.

## Decision

Every completed recording starts processing immediately. An auto-ended part
remains a Reconnect candidate for three minutes. The existing Notes / Reconnect /
Skip prompt and its 20-second timeout still require a choice; timeout and Skip
do not start recording. Manual Stop is final for the current call.

Reconnect records a fresh part in its own directory with its own provider
checkpoints. The first note can finish while the continued call is recording.
When that call ends, the same meeting shows Updating… and retains the earlier
note. Only the fresh audio is transcribed and summarized. Its summary and section
items supplement the existing note; this is an append, not a regenerated global
summary. Its transcript is appended at the cumulative recorded-audio offset,
with a reconnect boundary. Speaker labels are scoped to each part because two
independent diarization jobs cannot establish that their Speaker 1 is the same
person. Duration excludes the disconnected gap.

## Rationale and alternatives

Keeping processing behind a longer grace period repeats the original delay.
Re-transcribing all accumulated audio repeats provider work and risks reusing
an earlier provider checkpoint for different input. Separate recordings avoid
both problems and keep the prior note available when a later part fails.

## Ordering, recovery and edits

The coordinator registers and serializes processing per logical meeting before
returning from Stop. Each physical recording has a durable manifest, including
its parent and preceding recording. A continuation waits for its preceding part
to be committed; failure leaves the audio staged for recovery. Launch recovery
processes parts in chronological order and never skips an unfinished continuation
merely because the original note exists. Wake recovery excludes a live recording
and its suspended start. An interrupted continuation retains its association;
recovery discovers its flushed WAV chunks.

The store commits metadata, an idempotency receipt and a complete note/transcript
snapshot in one SQLite transaction. Canonical sidecars are materialized after
the commit. Until both writes succeed, readers use the committed snapshot. Edits
and backup export flush it first. A replay after a crash cannot append twice.
Continuation additions carry their note versions so an editor opened before an
update can save its changes without discarding the new findings. The existing
title and edited content are preserved; an untouched No speech detected
placeholder can be replaced when the next part contains speech.

Deletion is refused while a continuation records or a processing job is active.
Deleting a finished meeting clears its reconnect candidate, continuation
manifests and processing receipts. Failures retain the previous note and the
unprocessed audio.

## Comments and objections

No silent resume or inference that the next call is the same meeting is added.
The user explicitly chooses Reconnect or a new note. The prompt's earlier
visibility report is separate: local logs established creation and timeout,
but did not establish why the user did not see it.

## Resolution and consequences

The grace period controls only the available choice, not note latency. A failed
later part leaves an earlier readable note with the failure status. Real-call
capture, prompt visibility and installed-app acceptance remain release checks.

The new SQLite tables are additive. An older binary does not understand
continuation manifests, so rollback must wait until no continuation recording
or recovery work remains; it must not process these manifests as standalone
meetings. Preserve the current app and data if that condition is unknown.

## Supersedes

This replaces the delayed-processing aspect of the 45-second implementation.
The explicit-choice rule in `docs/decisions/2026-07-29-reconnect-always-asks.md`
and manual Stop semantics remain in force.

## Verification

Synthetic provider, temporary-store and fake-recorder tests cover immediate
processing, the three-minute boundary, ordering, append/replay recovery, partial
manifests, scoped speakers, silence, readable Updating state, and concurrent
note edits. These checks do not claim live-device or installed-app acceptance.
