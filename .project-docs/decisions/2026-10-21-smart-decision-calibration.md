---
id: smart-decision-calibration-2026-10-21
type: decision
title: Calibrate Jev routing against actual dictation benefit
summary: Keep the measured Jev prompt and use a model-specific 0.50 routing cutoff; optional rewriting is not evidence that editing was useful.
status: observed
tags: [smart, decision, jev, calibration, dictation, context, telegram]
canonical_for: [smart-decision-calibration]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: 2026-10-21 Smart Decision chat; user authorized analysis of actual raw dictations and their edited results, and calibration based on whether editing was useful.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: 2026-10-21 same chat; future Smart behavior should adapt to the destination application and its supported formatting, particularly Telegram.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/AIRouting/SmartTextDecision.swift
    confirmed_at: 2026-10-21
  - type: url
    reference: https://docs.typesafe.ai/primitives/noul
    confirmed_at: 2026-10-21
related: [2026-10-21-smart-decisions.md]
---

# Jev routing calibration

## Observation and method

The initial 0.05 cutoff routed every evaluated clear-cut example to editing.
The user asked for an assessment of editing benefit, rather than counting every
difference between recognition and generated text as a necessary correction.

With the user's authorization, inspect a frozen set of 124 actual dictation
pairs from 2026-10-21. Assign labels before requesting scores: 31 need repair,
14 benefit from structure/condensation, 62 are already usable, 14 are borderline,
and 3 are excluded (filler-only, explicit translation, unfinished intent).
Labels are an agent's editorial judgments, not user-confirmed ground truth.
Conversational vocabulary, profanity, harmless word-order changes and optional
formalization are not sufficient reasons to label a message as needing editing.
An edited result can itself be wrong; it is not the reference answer.

Split deterministically before scoring: 77 clear-cut development examples and
30 clear-cut held-out examples. Borderline examples do not select the cutoff.
Replay raw text, recorded target-app name and language to the configured Jev
route. Historical screen context was not retained, so replay lacks that evidence.
These are new scores, not recovered historical decision probabilities.

Compare the original prompt with softer English/Russian benefit prompts,
separate recognition/self-correction/structure questions and categorical routes.
The alternatives reduced unnecessary editing but missed more useful repairs.
Among candidates preserving all 28 useful development edits, the original
prompt at 0.50 skipped the most unnecessary editing (25 of 49).
Freeze that choice before evaluating the held-out set.

| Sample | Useful edits kept | Useful edits missed | Unnecessary edits sent | Unnecessary edits skipped |
| --- | ---: | ---: | ---: | ---: |
| Development, old 0.05 | 28 | 0 | 49 | 0 |
| Development, selected 0.50 | 28 | 0 | 24 | 25 |
| Held-out, old 0.05 | 17 | 0 | 13 | 0 |
| Held-out, selected 0.50 | 16 | 1 | 6 | 7 |

The held-out miss involved a possible misrecognized service name. A subsequent
repeat using the exact runtime question name/schema retained 43 of 45 useful
edits and skipped 31 of 62 unnecessary edits (development: 27/28 and 25/49;
held-out: 16/17 and 6/13). Two routing outcomes changed near the cutoff; the
second missed repair was another misrecognized technical name. The cutoff
was not retuned after either validation. Missing
historical context limits the conclusion. The remaining 31 unnecessary edits
across both sets show that the classifier still does not fully capture the
editorial rubric. A cutoff does not retrain model weights or establish that
its numeric outputs are calibrated real-world frequencies.

## Decision

Apply the 0.50 cutoff only to OpenRouter's exact `typesafe/jev-1.14` route.
Keep its measured prompt as a separate immutable candidate from other Decision
adapters' instructions. Another Jev version or OpenAI keeps the previous 0.05
policy until independently evaluated. Do not automatically substitute models.

Preserve translation bypass, app/language context, filler handling, malformed
response validation, timeout fallback to the configured editor and Retry.
Do not add transcript or probability logging to the runtime journal.
Private pairs and replay responses remain local in ignored build output;
only aggregate results belong in source control and public review.

## Future context behavior

The accepted direction is for both the decision and the editor to consider
the destination: casual chat, a document and an AI prompt can have different
editing and structure needs. Sol can use an explicit destination capability
profile. Formatting for Telegram needs an actual paste-path check before
claiming Markdown or rich-text support; its client is not assumed to interpret
an API's formatting syntax. This calibration does not implement such profiles.

## Consequences and verification

Across the final 107 clear-cut replays the selected rule skips 33 editing
passes, including 31 of 62 unnecessary edits, and retains 43 of 45 useful edits.
This small, single-user, predominantly AI-chat corpus is not a general quality
guarantee. Observe further real dictations before widening the cutoff or
changing the measured prompt. Synthetic tests verify routing boundaries,
model isolation and context transport; they do not prove classifier accuracy.
