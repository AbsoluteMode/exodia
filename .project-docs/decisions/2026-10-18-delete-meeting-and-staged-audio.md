---
id: delete-meeting-and-staged-audio-2026-10-18
type: decision
title: Delete removes everything of a meeting; a stored meeting keeps no staged audio
summary: Delete on a finished meeting removes its staged recording, row, note and transcript files; launch recovery frees the whole staged directory of a meeting that already has a note.
status: confirmed
tags: [meetings, recovery, storage]
canonical_for: [meeting-deletion, staged-audio-cleanup]
verified_at: 2026-10-18
sources:
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsCoordinator.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsStore.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/Meetings/MeetingsStagedAudioCleanupTests.swift
    confirmed_at: 2026-10-18
related: [2026-10-18-silent-meetings.md, 2026-09-07-soniox-meeting-files.md]
---

# Deleting a meeting, and staged audio of stored meetings

## Context

An inventory of `~/Library/Application Support/Sidekey/meetings-staging` on
2026-10-18 found 52 directories and 6.2 GB. 49 of them belonged to meetings
that were already stored, left by the retired cloud pipeline and its
migration. The app removes a staged directory only at the end of a successful
run, so nothing ever cleaned the rest.

Two code paths created or kept such leftovers:

- Launch recovery of a meeting that already has a note dropped only
  `manifest.json` and left the audio and the Soniox checkpoint behind.
- A failed meeting had no way out. The list has no Delete, and
  `MeetingsStore.delete(id:)`, which nothing called, removed only the database
  row and left `<id>.md` and `<id>-transcript.json` on disk. A silent
  509-second recording stayed in the list as a red row from 8 September.

## Decision

1. Launch recovery of a meeting that already has a stored note removes its
   whole staged directory (audio, separate tracks, checkpoint, manifest). A
   ready row without a note keeps its audio and only loses the stale manifest.
2. A finished meeting (`ready` or `failed`) has "Delete…" in its row context
   menu. A confirmation comes first; Cancel is the default button.
   `MeetingsCoordinator.deleteMeeting(id:)` removes the staged directory first,
   then calls `MeetingsStore.delete(id:)`, which removes the row and then the
   note and transcript files. A meeting that is unknown or still being
   processed is refused, and any failure leaves the meeting in the list and is
   shown to the user.

## Rationale

- The processors already delete the staged directory right after the insert.
  What recovery finds next to a stored note is the unfinished end of that same
  step, not a backup.
- Without a note the audio is the only source left, so it stays. Deleting on
  `ready` alone would destroy it.
- While a manifest exists, launch recovery re-processes the recording and
  inserts the meeting again. The staged directory therefore goes before the
  row, and if its removal fails the row stays, so nothing is half deleted and
  the user can retry.
- Removing only the row leaves the note and transcript text on disk, which
  contradicts Delete.
- A meeting that is still processing would be inserted again by its processor
  when it finishes.
- An unknown id never removes a staged directory: audio without a meeting may
  be a lost recording, and that is the user's decision.

## Verification

New tests, each named after the break it catches:

- recovery frees the whole directory of a stored meeting, keeps the audio when
  the note is missing, and leaves the directory of an unprocessed meeting alone;
- Delete removes row, note, transcript and staged audio; a deleted failed
  meeting is not brought back by launch recovery; in-progress states are
  refused; a failed staged removal keeps the row; an unknown id deletes
  nothing;
- the store removes both files, tolerates a row without files, and can be
  repeated;
- the list asks with the meeting's title ("Untitled" for none), deletes only
  after a yes, reloads, and reports a failed delete.

All tests that exercise new behaviour failed before the change for the
expected reason. Seven deliberate mutations (no in-progress guard, row deleted
before the staged directory, unknown id deletable, audio freed on `ready`
alone, transcript file kept, answer ignored, failure not reported) were each
caught by the test written for it.

Not verified: the context menu and the alert in the running app. Both act on
real meetings, so they were not exercised outside unit tests.

## Alternatives

- Sweep old staged directories automatically at launch. Not done here:
  directories of the old cloud pipeline carry their own ids and cannot be
  recognised by name, so they were cleaned once by hand after an inventory. A
  sweeper for directories named after a stored meeting remains a separate
  decision.
- Delete the row only, as `delete(id:)` did. Rejected: note and transcript text
  stay on disk.
- Delete the row first and the staged recording second. Rejected: a failure
  in between leaves a manifest that brings the deleted meeting back.
- Clean remote Soniox resources on Delete. Not done: it needs the API key and
  the network at Delete time. The checkpoint with their ids goes with the staged
  directory, and the confirmation says "removed from this Mac". A failed
  meeting whose job still exists is better retried (see the silent-meetings
  decision) than deleted.

2026-10-18, this branch.
