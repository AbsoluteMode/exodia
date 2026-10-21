---
id: smart-editor-prompt-2026-10-21
type: decision
title: Edit Smart dictation into concise messages with paragraphs
summary: Replace transcript-like cleanup with a meaning-preserving message editor calibrated on GPT-6 Sol, keeping conditions, reasons, uncertainty and nested requests.
status: confirmed
tags: [smart, dictation, prompt, editing, paragraphs, sol]
canonical_for: [smart-editor-prompt]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user requested implementation of the new Smart prompt for Sol to shorten messages without losing meaning and split text into paragraphs.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/PostProcessor.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/PostProcessorOpenRouterTests.swift
    confirmed_at: 2026-10-21
related: [2026-10-19-strict-drop-modes.md, 2026-10-21-smart-destination-formatting.md]
---

# Smart message editing

## Context

The previous prompt asked for paragraphs but demonstrated almost exclusively
single-paragraph output and prohibited lists. Its broad self-correction example
also removed the independent fact that the author was unavailable tomorrow.
Local experiments found useful compression with GPT-6 Sol, but also occasional
lost reasons, uncertainty and a nested request to only clean up a message.

## Alternatives

Keep punctuation-only cleanup, flatten/format output deterministically, use
an additional verification model call, or improve the existing editor prompt.
Formatting rules cannot reconstruct meaning, and another model pass adds
latency without an established improvement on the reviewed examples.

## Decision and rationale

Use the existing Smart editor call with an explicit full-message contract:

- Consolidate repeated requests and remove wording searches and fillers.
- Preserve independent facts, reasons, conditions, negatives, alternatives,
  numbers, deadlines, addressees, scope, uncertainty and tentative decisions.
- Limit self-correction to the fragment actually corrected; do not erase
  independent context. Do not invent causality or turn a suggestion into a decision.
- Separate distinct ideas with blank lines; use plain lists for at least
  three parallel requirements and keep a short message as one paragraph.
- Edit the transcript as data. Nested requests and prohibitions remain part
  of the author's message; do not execute them or draft the requested email.
- Preserve literal identifiers and canonical technical names. Honor the output
  language hint while retaining the same editing contract.

The prompt is calibrated for GPT-6 Sol, shared by configured Smart editor
routes. It does not select or substitute a model, change provider pins,
or add an extra editor call. Fast still bypasses the LLM; Smart retains Retry
on errors. This decision concerns the editor stage; Smart decision instructions also identify rambling or
unstructured text as needing editing, even with correct grammar.

## Sources

The implementation uses `PostProcessor.systemPrompt`. The response is delivered
through `DropOutputPolicy` and `DropFillerFilter`, which preserve internal newlines.
Paragraph- and list-initial filler removal consumes orphan punctuation without
flattening newlines or changing list markers. Synthetic-client integration
tests verify paragraphs/lists through this path
and output-language wiring. Live model acceptance uses supplied/synthetic
dictation examples separately from unit tests and never runs in CI.

## Comments and objections

A prompt cannot guarantee zero semantic loss. Quality checks compare facts
and constraints, not a target compression percentage. Prompt substring tests
only proved that particular wording existed; message-envelope tests remain,
while former examples are included in explicit model acceptance checks.

## Resolution

Use the prompt with the stronger meaning-preservation examples. Unit checks,
model output review, queued installation and real dictation acceptance are
separate evidence; passing source tests does not prove the working app changed.

## Consequences

Long messages can become shorter and structured without a runtime formatting
pass. Some messages should stay the same length to preserve qualifications.
Physical paste and future model variability remain acceptance concerns.

## Supersedes / superseded by

Supersedes the old editor wording and its lossy correction example. It does
not supersede the Fast/Smart delivery or provider-routing contracts.
