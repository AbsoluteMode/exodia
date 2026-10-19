# Meeting Assistant capture test

This collects evidence for a live assistant. It does not show question
suggestions or replace normal meeting notes.

1. In **API & Models**, choose Soniox for **Meetings** and configure the usual
   **Meeting notes** route.
2. In **Other**, enable **Meeting Notes** and **Meeting Assistant test capture**.
   Testing adds a Soniox streaming transcription request.
3. Start notes normally at the next call. Include separate speech from each
   side, then brief overlap. Exercise Pause/Resume if convenient.
4. Stop normally and allow a few seconds for the independent stream to drain.
   The note processes as before.
5. Use **Other → Meeting test files → Open folder**. UUID folders contain private
   audio and text. Delete unwanted test folders in Finder; deleting a normal
   note does not delete these bundles. Turn the toggle off after testing.

An offline report without transcript content:

```sh
python3 scripts/meeting-test-report.py /absolute/path/to/test-bundle
```

`state: complete` means normal stream completion. Missing keys, provider or
transport errors, queue overflow, the two-hour limit and final timeouts require
investigation; they do not mean normal notes failed. An interrupted app may
leave `state: recording`. Inspect timing warnings even after completion.

The three audio files are raw signed little-endian PCM16, 16 kHz, mono.
They use the test stream's audio clock: pause and prerecord are excluded.
Source placement uses callback arrival estimates, not hardware timestamps.
Role estimates use signal activity and online speaker anchors. `unknown` is
expected for early words, overlap and uncertainty. Echo, background sound and
shared microphones can invalidate the source assumption.

The report measures final-token delay from frame emission, excluding the
test mixer's jitter buffer. Full live latency and attribution need real-call
acceptance. A confusion matrix also needs independent human labels for
questions addressed to the local user. See the
[capture decision](../.project-docs/decisions/2026-10-19-live-meeting-test-capture.md).
