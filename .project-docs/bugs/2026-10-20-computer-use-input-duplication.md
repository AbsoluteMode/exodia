---
id: computer-use-input-duplication-2026-10-20
type: bug
title: Open Computer Use input duplication and stray paste incident
summary: Typing and paste recovered after resetting only the Computer Use helper; native filter persistence is reproducible, but the duplication trigger and permanent fix remain unknown.
status: confirmed
lifecycle: open
resolution: null
tags: [computer-use, codex, keyboard, clipboard, drop, history, macos, open-bug]
canonical_for: [computer-use-input-duplication]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: Codex chat 01a15955-c519-7b90-baad-d79f6e3ba440 on 2026-10-20; user reported paired physical keystrokes, repeated and previous clipboard pastes, unexpected image attachment, and broken history paste, then confirmed all functionality returned after the helper reset.
    confirmed_at: 2026-10-20
  - type: user-confirmed
    reference: The same chat on 2026-10-20; user requested leaving this as an open bug and enabling diagnostic logging.
    confirmed_at: 2026-10-20
  - type: trace
    reference: Local-only $HOME/.codex/diagnostics/keyboard-duplication-2026-10-20/summary.json and lifecycle-*.txt; raw evidence is not committed or uploaded.
    confirmed_at: 2026-10-20
  - type: repository
    reference: scripts/diagnostics/computer_use_routing_logger.py
    confirmed_at: 2026-10-20
  - type: repository
    reference: scripts/diagnostics/event_tap_inventory.swift
    confirmed_at: 2026-10-20
related: [../processes/computer-use-input-diagnostics.md]
---

# Open bug: Computer Use input duplication

The bug is **open**, with an unknown root cause and no permanent fix.
Successful recovery, a clean sample, or enabling diagnostics does not close it.
This is a local project bug record; no upstream issue has been filed.

## Confirmed incident and recovery

On 2026-10-20, physical typing doubled individual characters in Codex. Drop and
paste sometimes repeated a phrase or inserted earlier clipboard content, including
an unexpected image. History's Enter-to-paste action also failed. The user observed
duplication in standalone Dia website fields while its address bar and Claude Code
behaved normally; Dia symptoms were intermittent.

Normal termination of only the verified `SkyComputerUseService` removed its event
taps. The user confirmed that all functionality returned. Whytap and Codex retained
their original running processes; neither was restarted. This strongly implicates
Computer Use event handling in this episode, without proving a particular defect.

Observed versions: Codex `26.1013.40934 (20770)`, Computer Use helper
`26.1013.1001501 (1001501)`, Whytap `2.2.17 (1502)`, source
`495c2f8b521e2ee2462e13d526bf96aede7cc068`.

## Reproducible lifecycle observation

A bounded experiment started with no Computer Use taps. Reading Whytap's window
added one global listen-only observer. The first keyboard command against the
observed idle island added seven taps, including two active per-process keyboard
filters targeting Whytap. `cua_repl.js_reset` left all eight helper-owned taps in
place. Rebinding reused the same tap IDs; repeated-call accumulation was not shown.
Normal helper termination removed them. A new helper can appear without active
per-app filters, and helper process presence alone is not evidence of interference.

Persistent filters may be intentional background-routing state. Their existence
or count alone does not prove duplicate key delivery. No new user-confirmed symptom
reproduction was established during this lifecycle experiment. The first aggregate
duplicate counter omitted target PID, so its annotated-stage counts cannot establish
duplicate delivery to one field. Whytap logged one paste dispatch per observed take.

## Diagnostics and first action

Use the [local diagnostic procedure](../processes/computer-use-input-diagnostics.md).
It records process identity and tap inventory, never keyboard events or content.
At the next symptom, capture an incident **before** helper recovery removes the
state. The logger does not detect doubled text or decide whether a paste is wrong;
correlation still requires the user's symptom report.

Recovery remains a workaround: release native Computer Use routing only when no
other Computer Use operation is active. Preserve Codex and Whytap processes and
permissions. Do not patch vendor binaries or automatically retry a suspect paste.

## Resolution requirements

- Identify and reproduce the actual duplication trigger, beyond tap persistence.
- Establish which component owns the defect and implement or obtain its fix.
- Verify physical typing, a fresh Drop paste and history paste during and after a
  Computer Use task, including the supported background-use case.
- Record the fixed version and user acceptance before changing lifecycle to closed.
