---
id: delete-meeting-and-staged-audio-2026-10-18
type: decision
title: Delete removes everything of a meeting; a stored meeting keeps no staged audio
summary: Delete on a finished meeting removes its staged recording, row, note and transcript files, the row only once both files are gone; a note save after Delete writes nothing; launch recovery frees the whole staged directory of a meeting that already has a note.
status: confirmed
tags: [meetings, recovery, storage]
canonical_for: [meeting-deletion, staged-audio-cleanup]
verified_at: 2026-10-19
sources:
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsCoordinator.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsStore.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Tests/SidekeyTests/Meetings/MeetingsStagedAudioCleanupTests.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Tests/SidekeyTests/Meetings/MeetingsStoreDeleteTests.swift
    confirmed_at: 2026-10-19
related: [2026-10-18-silent-meetings.md, 2026-09-07-soniox-meeting-files.md, 2026-10-22-clipboard-entry-delete.md]
---

# Deleting a meeting, and staged audio of stored meetings

## Context

An inventory of `Application Support/Sidekey/meetings-staging` on
2026-10-18 found 52 directories and 6.2 GB. 49 of them belonged to meetings
that were already stored, left by the retired cloud pipeline and its
migration. The app removes a staged directory only at the end of a successful
run, so nothing ever cleaned the rest.

Two code paths created or kept such leftovers:

- Launch recovery of a meeting that already has a note dropped only
  `manifest.json` and left the audio and the Soniox checkpoint behind.
- A failed meeting had no way out. The list has no Delete, and
  `MeetingsStore.delete(id:)`, which nothing called, removed only the database
  row and left the Markdown note and `<id>-transcript.json` on disk. A silent
  509-second recording stayed in the list as a red row from 8 September.

## Decision

1. Launch recovery of a meeting that already has a stored note removes its
   whole staged directory (audio, separate tracks, checkpoint, manifest). A
   ready row without a note keeps its audio and only loses the stale manifest.
2. A finished meeting (`ready` or `failed`) has "Delete…" in its row context
   menu. A confirmation comes first; Cancel is the default button.
   `MeetingsCoordinator.deleteMeeting(id:)` removes the staged directory first,
   then calls `MeetingsStore.delete(id:)`. It deletes the row inside a
   transaction, removes the transcript and then the note file, and commits
   only when both are gone; any failure rolls the row back. A meeting that is
   unknown or still being processed is refused, and any failure leaves the
   meeting in the list with its note and is shown to the user.
3. A note save that lands after Delete (the editor saves after a 500 ms
   debounce) writes nothing. `MeetingsStore.update` updates the row first and
   writes the Markdown note only when a row matched; `saveNoteEdit` drops the save
   without an alert.

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
- The failure alert says the meeting is still in the list. When the row was
  deleted and committed before the files, a file that could not be removed
  left the meeting gone from the list while the alert said otherwise. With the
  row's delete committed only after the files, the alert is true: a failed row
  delete has touched no file yet, and a failed file removal is rolled back.
- The transcript goes before the note, and the first failure stops the
  removal. A meeting that stays listed after a failure therefore keeps its
  note; at worst its transcript is already gone, which the user asked for,
  and a second Delete finishes the job.
- A save that lands after Delete belongs to a note the user has just deleted,
  so Delete wins. Writing the file before the row update recreated the Markdown note
  without a row: the deleted text was back on disk with no way to remove it
  from the app. The save gets no alert because the user has nothing to do.
- Known limit: if `COMMIT` itself fails after both files are gone (a disk I/O
  error, or another process holding the database open; the app itself uses
  one connection), the row stays without its note. The alert is still true,
  and a second Delete succeeds because missing files are fine.

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

2026-10-19 follow-up, tests named after the break each catches:

- a save that lands after Delete brings no note back (store and coordinator);
- a transcript that cannot be removed keeps the meeting listed with its note;
- a note that cannot be removed keeps the meeting listed;
- a row whose delete fails (a test trigger refuses it) keeps the note and the
  transcript.

All but the last failed before the change for the expected reason. The last
passed then, because the row went first; it fails when the files are removed
before the row without a transaction. Removing the note before the transcript
is caught by the transcript test. A file removal is made to fail with the
user-immutable flag, which keeps the directory and the database journal
writable.

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
- Keep the row-first order and make the alert say the meeting was deleted but
  some files remain. Rejected: those files then have no row, so nothing in
  the app can retry or remove them.
- Remove the files first and the row second, without a transaction.
  Rejected: a failed row delete then leaves a listed meeting without its note.
- Move the files aside and restore them on failure. Rejected: more moving
  parts, and the restore can fail as well.
- Clean remote Soniox resources on Delete. Not done: it needs the API key and
  the network at Delete time. The checkpoint with their ids goes with the staged
  directory, and the confirmation says "removed from this Mac". A failed
  meeting whose job still exists is better retried (see the silent-meetings
  decision) than deleted.

2026-10-18, PR https://github.com/AbsoluteMode/exodia/pull/20.
2026-10-19, row committed after the files and no late note saves: PR
https://github.com/AbsoluteMode/exodia/pull/32.
