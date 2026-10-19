---
id: whytap-translation-tools
type: decision
title: Text translation and system-audio subtitles inside Whytap
summary: Bring the standalone translator journeys into two native tools using the existing per-feature provider routes.
status: confirmed
tags: [translation, subtitles, system-audio, llm, tools]
canonical_for: [translation-tools]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 the user requested integration of Realtime Translator system-audio translation and its LLM translator into Whytap, with polished and reliable feature behavior.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Translation/LiveSubtitleModel.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Translation/TranslationService.swift
    confirmed_at: 2026-10-20
related: [../project.md]
---

# Translation tools

## Context

The user requested both journeys from the standalone Realtime Translator:
floating system-audio subtitles and quick text translation. Whytap already has
system-audio process taps, speech adapters, Keychain storage, per-feature routes
and optional named tool hotkeys.

## Alternatives

Copying the standalone application's OpenAI endpoint, credential files and
independent hotkey registrar would create parallel setup and lifecycle paths.
Using the existing speech adapters followed by the configured text model fits
the application's current provider and key choices.

## Decision

Use two catalog tools, Translate and Subtitles, opening one native floating
window. Preserve the standalone RU/EN automatic text direction and offer
explicit targets. Keep original speech optional beside subtitles.

The implementation uses two new routes: Translation (LLM, shared by typed text
and subtitle phrases) and Subtitles audio (real-time speech). Both start unset;
existing routes and layouts are preserved. This provider pipeline is an
implementation choice, not a user-selected provider or model.

## Rationale

A single setup, capture implementation and cancellation path avoid a second
credential store or app. Final-only phrase translation reduces redundant
requests. Bounded audio and phrase queues stop visibly when a provider cannot
keep up. Generation guards reject late responses after editing or cancellation.

## Sources

The request and source paths above; public usage and verification limits are
in [the translation guide](../../docs/translation.md).

## Comments and objections

Live provider quality and latency remain unverified until installed-app
acceptance. A two-stage pipeline has different latency from the standalone
OpenAI audio-to-translation model. No equivalence claim is made.

## Resolution

Keep provider choice explicit in API & Models. Expose errors and retry through
the native window; never substitute another model automatically.

## Consequences

Closing or sleeping stops capture and requests. App-initiated update restart
waits for translation. No system-audio recording or automatic translation
history is written to disk. Only the most recent forty subtitle lines remain.

## Supersedes / superseded by

None. Existing Drop translation and meeting recording contracts remain active.
