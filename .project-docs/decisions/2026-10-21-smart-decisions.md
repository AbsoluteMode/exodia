---
id: smart-decisions-2026-10-21
type: decision
title: Use a Decision model before Smart text editing
summary: Smart uses Jev 1.14 through OpenRouter by default to decide whether text needs editing, with an explicit OpenAI Decisions alternative. Uncertainty keeps full Smart processing.
status: confirmed
tags: [drop, smart, fast, decision, jev, openrouter, openai]
canonical_for: [smart-decision-routing]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: 2026-10-21 Smart Decision chat; user specified openrouter typesafe/jev-1.14, required it inside Smart by default, and identified Decision as a separate model type.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/AIRouting/SmartTextDecision.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/PostProcessor.swift
    confirmed_at: 2026-10-21
  - type: url
    reference: https://openrouter.ai/blog/insights/what-is-jev/
    confirmed_at: 2026-10-21
  - type: url
    reference: https://developers.openai.com/api/docs/guides/decisions
    confirmed_at: 2026-10-21
related: [2026-10-19-strict-drop-modes.md, 2026-10-21-smart-decision-calibration.md]
---

# Smart Decision routing

## Context

A clean dictated message does not always need a text-generation pass. The user
requested Jev as the default decision stage within Smart, with a separate model
selection and an OpenAI Decisions option. Decision returns typed judgments and
probabilities, not edited prose.

## Alternatives

Always editing keeps the earlier Smart contract but spends a generation on clean
text. Asking an ordinary LLM for a verdict generates prose and is not the Jev
integration requested. Neither replaces the accepted decision stage.

## Decision

- Add the distinct `decision` model use and `dropSmartDecision` feature. Show
  Speech → Decision → Text in the existing Drop Smart disclosure.
- Initialize the new route once to OpenRouter `typesafe/jev-1.14`. Preserve all
  existing routes. Missing OpenRouter credentials never borrow another key;
  removing a key does not recreate the decision route on a later launch.
- Offer OpenAI `gpt-6-luna` through its dedicated Decisions endpoint when the
  user explicitly selects it. The two adapters use their own provider keys.
- Evaluate whether the transcript needs editing, using the same app/language
  references as cleanup. Treat every input field as data, never instructions.
- Skip editing only for a valid needs-cleanup probability no higher than the
  model-specific cutoff: 0.50 for exact OpenRouter `typesafe/jev-1.14`, 0.05
  otherwise. The linked calibration record owns the evidence and limitations.
  Return the original text through the existing filler/output policy. Keep the
  take's Smart mode, speech route, recovery and Retry identity unchanged.
- Explicit output-language conversion always uses the editor. Inputs longer
  than 16,000 characters keep Smart without truncating the decision evidence.
- An absent route/key, uncertain or malformed answer, refusal, transport error
  or two-second request deadline continues to the selected Smart editor. An
  editor error or empty result still retains the transcript for Retry.
- Decision models are not offered for generated text or agent tools. Synthetic
  Check now requests use the decision endpoint and are excluded from costs.
  Runtime requests record provider-reported cost when supplied, otherwise
  unavailable, without retaining input or response text in the journal.

## Rationale

The Fast path is an explicit successful decision. A decision outage cannot turn
a failed Smart cleanup into an automatic raw paste. Existing cleanup configuration
must still be valid before taking the fast path.

## Sources

The user request establishes the product behavior. The linked provider pages
establish the two HTTP schemas; repository sources and synthetic tests establish
the local implementation. No real user content or paid inference is used in tests.

## Comments and objections

The initial 0.05 cutoff was a conservative implementation policy. The linked
calibration record supersedes that cutoff for Jev 1.14 after actual dictation
analysis; other models remain uncalibrated. A confident decision can be wrong.
The two-second deadline caps added waiting when the service is unavailable.

## Resolution

Implement separate typed adapters and preserve strict Smart failures. Configure
Decision independently from speech and cleanup in API & Models.

## Consequences

Clean messages can avoid a generation pass. Messages requiring editing pay an
extra decision call and its latency. Jev is used through the user's OpenRouter
account; no TypeSafe account or additional Whytap service is introduced.

## Supersedes/superseded by

Extends the successful-output rule in `2026-10-19-strict-drop-modes.md`: a confident
clean verdict is now a valid Smart result. Its failure, Retry and take-latching
rules remain. No later superseding decision is known.
