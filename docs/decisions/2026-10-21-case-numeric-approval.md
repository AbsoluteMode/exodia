---
id: case-numeric-approval
type: decision
title: Case approval intercepts only bare digit answers
summary: Historical mistaken interpretation, superseded by restoring Y/N/A and restricting only the minutes field to digits.
status: stale
tags: [case, approval, hotkeys, input]
canonical_for: []
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user clarified that digits-only referred to the minutes field; they did not request replacing Y/N/A answer shortcuts.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Case/Approval/CaseApprovalKeyTap.swift
    confirmed_at: 2026-10-21
related: [2026-10-21-case-approval-minutes-input.md, 2026-10-19-case-secrets-broker.md, ../hotkey.md, ../DESIGN.md]
---

# Numeric Case approval

Historical implementation based on a mistaken interpretation. The user
corrected it the same day: keep Y/N/A and restrict only the minutes input.
[Answer keys and numeric minutes](2026-10-21-case-approval-minutes-input.md)
supersedes the implementation below.

Only bare physical 1/2/3 answer the visible request: 1 denies, 2 allows once,
3 grants temporary Bypass for the displayed minutes. Both the top row and
numeric keypad work. This follows the bottom row left-to-right, reserving 3
for the separate temporary action. The tap, card and Help share the keycap
definitions.

All letters, Escape, navigation, other digits and modified digits pass through.
Shift is excluded so typing punctuation does not answer a request. This
supersedes the original Y/N/A/Escape mapping. The local duration editor still
handles its own Return/Escape while editing, with the approval tap unarmed.

Keep the 300 ms quiet period, held-key/repeat ownership, 60 s timeout, click
fallback, authentication, queue and grant scope unchanged. No default grant,
saved-policy or credential migration accompanies the key change.
