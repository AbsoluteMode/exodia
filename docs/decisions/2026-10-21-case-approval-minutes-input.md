---
id: case-approval-minutes-input
type: decision
title: Keep Y/N/A answers and restrict only Case minutes to digits
summary: Correct the numeric-shortcut misunderstanding, reject non-digit duration edits, and keep initial panel focus off the duration field.
status: confirmed
tags: [case, approval, hotkeys, input, focus]
canonical_for: [case-approval-answer-keys, case-approval-minutes-input]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user clarified that only the minutes field should reject letters, expected the original Y/A/N shortcuts, reported selected duration text on appearance, and said answer keys were not working.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Case/Approval/CaseApprovalView.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Case/Approval/CaseApprovalKeyTap.swift
    confirmed_at: 2026-10-21
related: [2026-10-21-case-numeric-approval.md, 2026-10-19-case-secrets-broker.md, ../hotkey.md, ../DESIGN.md]
---

# Answer shortcuts and numeric minutes

Restore the original physical Y/N/A answers and Escape denial outside editing.
The earlier 1/2/3 change was an assistant misunderstanding, not the requested
product behavior. Preserve current English labels and all access/grant policy.

Only the duration field is digits-only. A native formatter rejects letters,
punctuation and mixed pastes before insertion. Empty/out-of-range digit drafts
remain editable; existing validation and blur/Return restore the last valid
duration. Editing suspends approval keys, so rejected Y/N/A cannot grant access.

Give the panel an explicit neutral initial first responder and clear editing
when a new request appears. Duration focus and selection require an explicit
field action; normal keyboard/AX focus remains available. The original
offscreen no-presentation test did not reproduce the user's selected-field
report, so it does not establish a live compositor/focus cause.

Keep the 300 ms quiet period, held-key/repeat ownership, 60 s timeout, queue,
click fallback and grant scope. Synthetic native tests cover insertion/paste,
initial focus, editing and queue replacement; physical acceptance is separate.
