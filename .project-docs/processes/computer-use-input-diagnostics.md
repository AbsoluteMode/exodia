---
id: computer-use-input-diagnostics
type: process
title: Content-free local diagnostics for Computer Use input interference
summary: Run a bounded local tap and process inventory logger and capture its recent history before recovering from the open input-duplication bug.
status: confirmed
tags: [computer-use, diagnostics, input, clipboard, logging, privacy, launchd]
canonical_for: [computer-use-input-diagnostics]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: Codex chat 01a15955-c519-7b90-baad-d79f6e3ba440 on 2026-10-20; user requested diagnostic logging and an open bug record.
    confirmed_at: 2026-10-20
  - type: repository
    reference: scripts/diagnostics/computer_use_routing_logger.py
    confirmed_at: 2026-10-20
  - type: repository
    reference: scripts/diagnostics/event_tap_inventory.swift
    confirmed_at: 2026-10-20
related: [../bugs/2026-10-20-computer-use-input-duplication.md]
---

# Local input-routing diagnostics

This optional maintainer tool supports the
[open bug](../bugs/2026-10-20-computer-use-input-duplication.md). It is separate from
the shipped Whytap app and does not change its logging, settings or permissions.

## Collection and limits

The logger samples `CGGetEventTapList` and process metadata every five seconds.
It writes a record on a change and a heartbeat every minute. Each record contains
UTC time, process IDs/start times, tap owner/target IDs, event masks, tap mode and
enabled state. Known app versions are read from disk and explicitly labeled as
on-disk versions; a replaced bundle does not identify an older running process.

It never creates an event tap or receives keyboard events. It does not read
characters, key codes, clipboard content, window titles, screenshots, audio,
transcripts, prompts or credentials. It sends no network requests, performs no UI
actions, and never resets Computer Use or another app automatically.

Logs rotate at 2 MiB with seven backups (about 16 MiB total). Up to five incident
captures retain a snapshot and at most 2 MiB of preceding log each. Files are private
to the user by default. An active-per-app-filter count is diagnostic metadata,
not a symptom detector. State changes shorter than the five-second interval can
be missed; a log alone cannot prove a field received duplicate input.

## Enable and verify

From the checked source checkout, with macOS, Python 3 and Swift available:

```bash
python3 scripts/diagnostics/computer_use_routing_logger.py install
```

This compiles only the passive inventory executable, copies the diagnostic tool
under `$HOME/.codex/diagnostics/tools/input-routing/`, and starts the per-user
LaunchAgent `local.computer-use-input-routing`. It resumes at login and after an
unexpected logger failure. It does not package, launch, register or replace a
Whytap app. No extra macOS permission is requested.

```bash
python3 "$HOME/.codex/diagnostics/tools/input-routing/computer_use_routing_logger.py" status
```

`healthy: true`, a recent sample and an advancing sequence confirm collection.
Output lives under `$HOME/.codex/diagnostics/input-routing/`. A stale sample or
`last_error` means logging needs repair, not that input is healthy.

## At the next symptom

Stop repeated paste attempts. Before resetting the Computer Use helper, run:

```bash
python3 "$HOME/.codex/diagnostics/tools/input-routing/computer_use_routing_logger.py" capture --reason duplicated_typing
```

Other fixed reasons are `stray_paste`, `history_paste_failed`, `recovered`, and
`diagnostic_check`. No free-text payload is accepted. Save the returned capture
path in the open bug's local evidence, together with the user's report and its
time. Then apply the existing bounded helper recovery when no other Computer Use
operation is in progress. Do not repeat recovery during active work in another chat.

## Disable

```bash
python3 "$HOME/.codex/diagnostics/tools/input-routing/computer_use_routing_logger.py" disable
```

This removes only this logger's LaunchAgent and preserves logs and captures.

## Verification recorded on 2026-10-20

The maintainer's local logger was explicitly installed and reported healthy with
advancing five-second samples. A `diagnostic_check` incident captured a snapshot
and preceding log; a second `run` exited without starting a duplicate logger.
Three focused tests passed: active-filter attribution/content exclusion, bounded
capture size/five-capture retention, and cleanup after a failed capture. These
checks verify collection and retention, not absence of the input bug.
