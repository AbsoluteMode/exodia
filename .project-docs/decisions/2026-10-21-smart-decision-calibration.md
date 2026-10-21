---
id: smart-decision-calibration-2026-10-21
type: decision
title: Calibrate Jev routing against actual dictation benefit
summary: Measure explicit structural-edit instructions with a model-specific 0.40 routing cutoff; optional rewriting is not evidence that editing was useful.
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
related: [2026-10-21-smart-decisions.md, 2026-10-21-smart-editor-prompt.md]
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

## Compatibility check and revised calibration

Before integration, four synthetic controls checked the previous candidate
against the accepted Sol editor contract. The original prompt at 0.50 returned
0.38 for a grammatically clean, long, multi-topic block and 0.28 for a literal/
constraints case: both bypassed the editor, losing useful structure. The parallel
requirements case returned 0.81 (editor), and short-clean returned 0.05 (raw).
Thus the historical corpus did not establish compatibility with the new editor.
Its manual labels did not use Sol as a judge; exact historical editor prompts
were not retained. Keep those observations separate from the following check.

Add the accepted explicit requirement to edit long messages mixing distinct
unstructured topics, even when their grammar is correct. The measured Jev
question SHA-256 is now
`2cc0b99d305d93850f3922f8e35155b7d936dcde665f64ece549eb171497255f`.
Select 0.40 on the same development examples plus structural controls: retain
28/28 useful edits and skip 23/49 unnecessary edits. Freeze before the remaining
regression set. That set retains 17/17 useful edits and skips 5/13 unnecessary
edits. It was previously observed during the initial experiment and therefore
is a regression check, not a fresh independent hold-out for this revision.

Repeat the four controls with the revised exact runtime question/schema:

| Control | Probability | Branch | Structure and meaning |
| --- | ---: | --- | --- |
| Grammar-clean long multi-topic | 0.94 | editor | Separate topic paragraphs and release checklist; timing, test-card restriction, approvals and no-setting-change constraint preserved |
| Three parallel requirements | 0.93 | editor | Three bullets, Fast behavior, no model substitution, analysis-only scope preserved |
| Literal/constraints | 0.57 | editor | Two bullets, exact path, URL, key case, numbers and no-execution constraint preserved |
| Short-clean | 0.06 | raw | Exact text, one paragraph |

The first control uses one new exact `openai/gpt-6-sol` call with the integrated
editor prompt SHA-256
`edd3d8a739b9c21e1268624aebc04a31e2a110b9a1269d0b11ff6500980743e3`,
pinned to `openai/fast`, reasoning off. The parallel and literal controls reuse
the saved outputs for those exact inputs/model/prompt from the editor evaluation;
no new generation is claimed for those two. All four Decision calls are new.
Outputs were manually checked against explicit format and meaning criteria.
This is a small compatibility check, not physical dictation/paste acceptance.

## Decision

Apply the 0.40 cutoff only to OpenRouter's exact `typesafe/jev-1.14` route.
Keep its measured prompt as a separate immutable candidate from other Decision
adapters' instructions. Another Jev version or OpenAI keeps the previous 0.05
policy until independently evaluated. Do not automatically substitute models.

Preserve translation bypass, app/language context, filler handling, malformed
response validation, timeout fallback to the configured editor and Retry.
Do not add transcript or probability logging to the runtime journal.
Private pairs and replay responses remain local in ignored build output;
only aggregate results belong in source control and public review.

## Future context behavior

### Later short-message experiments: not promoted

The user subsequently reported that short correct messages still enter the
editor and may change only one valid word. The accepted target is concrete
repair for short messages, with useful structure retained for long ones.
Inspect 35 additional authorized raw/edited pairs, assigning labels before
scoring: 14 useful edits, 13 unnecessary, 7 borderline, 1 unfinished/excluded.
These are editorial judgments, not user-confirmed labels or historical model
scores. Do not infer a real defect solely from a changed word.

Five new English/Russian questions distinguish defects from synonyms, word
order, conversational vocabulary and minor punctuation. Test against the
earlier corpus, the additional pairs and fourteen structural/short controls.
The strongest explicit-example candidate at cutoff 0.25 retained 36/38 useful
development edits and skipped 34/57 unnecessary edits. A subsequent mixed
regression run missed useful grammar/name repairs; one provider HTTP 529 was
kept separate from classifier accuracy. In a new all-example replay it retained
55/59 useful edits and skipped 48/75 unnecessary edits. All five synthetic
short-repair controls passed, but real grammar misses remained. At 0.20 it
retained 58/59 and skipped only 34/75 unnecessary edits, offering no convincing
aggregate improvement over the existing pair. The repeated near-boundary
scores varied. Eight of 134 real-example requests in that replay took over
the runtime's 2s deadline and would keep the editor regardless of probability.
Replay latency is not a reconstructed measurement of the user's original takes.

These are reused tuning/regression examples, not an independent quality
estimate. Keep all alternative prompts/cutoffs out of production; the current
pair remains the structural prompt SHA-256 above and cutoff 0.40. Record the
unresolved short-message routing problem rather than declaring it fixed.
The separate conservative Sol change reduces rewriting when an unnecessary
editor pass still occurs; it does not establish that Jev skips that pass.

The accepted direction is for both the decision and the editor to consider
the destination: casual chat, a document and an AI prompt can have different
editing and structure needs. Sol can use an explicit destination capability
profile. Formatting for Telegram needs an actual paste-path check before
claiming Markdown or rich-text support; its client is not assumed to interpret
an API's formatting syntax. This calibration does not implement such profiles.

## Consequences and verification

Across the revised 107 clear-cut replays the selected rule skips 28 of 62
unnecessary editing passes and retains 45 of 45 useful edits in this sample.
This small, single-user, predominantly AI-chat corpus is not a general quality
guarantee. Observe further real dictations before widening the cutoff or
changing the measured prompt. Synthetic tests verify routing boundaries,
model isolation and context transport; they do not prove classifier accuracy.
