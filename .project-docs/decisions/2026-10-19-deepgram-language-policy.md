---
id: deepgram-language-policy-2026-10-19
type: decision
title: Use bounded multilingual recognition for Deepgram Auto
summary: Deepgram Auto explicitly uses the selected Nova model's documented multilingual mode, validates explicit languages and reports its limits without replacing saved models or providers.
status: confirmed
tags: [speech, deepgram, language, auto, realtime, batch, models]
canonical_for: [deepgram-input-language-policy]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: 2026-10-19 request to fix the audited input-language issues, including Deepgram Auto.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/DeepgramLanguagePolicy.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/DeepgramBYOKAdapter.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/ProviderBatchTranscriber.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/TranscriptionSessionFactory.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsModelsView.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Tests/SidekeyTests/Streaming/BYOK/DeepgramLanguagePolicyTests.swift
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developers.deepgram.com/docs/language
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developers.deepgram.com/docs/models-languages-overview
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developers.deepgram.com/docs/multilingual-code-switching
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developers.deepgram.com/docs/language-detection
    confirmed_at: 2026-10-19
related: [../bugs/2026-10-19-input-language-audit.md]
---

# Deepgram input language policy

## Context

The input-language audit found that omitting Deepgram's `language` parameter
made the UI's Auto selection use English. The omission occurred in realtime
and batch. The common language catalog was based on Soniox, so it also
offered combinations outside Deepgram Nova's advertised support.

## Decision

Use one `DeepgramLanguagePolicy` for realtime and batch requests. Auto sends
`language=multi` only for explicitly recognized Nova models. Keep the exact
chosen model and provider. Never add `detect_language` as a fallback.

| Saved model | Auto recognition | Explicit input |
| --- | --- | --- |
| `nova-3`, `nova-3-general` | en, es, fr, de, hi, ru, pt, ja, it, nl | Published Nova-3 language and locale set |
| `nova-2`, `nova-2-general` | en, es | Published Nova-2 language and locale set |
| `nova-3-medical` | Same ten languages as Nova-3 Auto | Published English locale set |
| Other saved/custom models | Configuration error | Send the chosen language unchanged; capability is unknown |

Empty or absent language means Auto. A recognized model with an unsupported
explicit language fails before transport creation or audio upload. The
factory wraps the failure as a setup error so Drop opens Models. Configuration
errors contain fixed messages, never the user's saved model or endpoint text.

Models shows the actual selected model, the exact Auto language coverage and
a supported input-language menu. A warning leaves an unsupported saved choice
visible until the user changes it. A saved model outside the current UI list
can be changed to Nova-3 only by explicit action followed by Save. Input-language
menu changes apply immediately to the shared preference. The connection
probe uses that current input language rather than unconditionally testing
Auto, so an explicitly configured custom model is not rejected as Auto.

Soniox's soft hints, its intentional English addition, other providers and
the unresolved Retry language-capture policy are outside this change.

## Alternatives

- Omit `language`: rejected because Deepgram defaults to English.
- Add `detect_language=true`: rejected because streaming does not support it
  and batch detection can replace the chosen model automatically.
- Set `multi` for every saved model: rejected because supported models and
  language coverage differ; an unknown model's protocol must not be guessed.
- Change provider or model automatically: rejected to preserve the user's
  chosen audio destination and processing model.
- Rewrite every shared language picker: deferred. Early validation prevents
  unsupported requests, and Models supplies the supported recovery choices.

## Rationale

The selected Nova model remains in control. Bounded multilingual recognition
supports Russian/English switching on Nova-3 without misrepresenting the
larger explicit-language catalog as Auto coverage. The same policy across
realtime and recovery avoids changing recognition semantics after a stream
failure. Unknown-model explicit input preserves existing custom routing
without claiming support that the application cannot establish.

## Sources and verification

The official language, model, multilingual and detection references in the
frontmatter establish the request semantics and capability tables. Source
tests cover exact Auto sets, unchanged explicit codes, unsupported choices,
unknown-model Auto errors and zero transport/upload on invalid configuration.
The audit record separates the pre-correction mock-test baseline from later
integrated verification and installed-application acceptance.

## Comments and objections

Auto covers ten languages on Nova-3, not every offered explicit input language.
The Models explanation makes that limitation visible. The shared hover picker
still has the wider catalog; choosing an incompatible Deepgram combination
produces a setup error and a route to supported choices rather than a request
that the selected model cannot fulfill.

## Resolution

Implement the bounded policy and explicit configuration errors in the source
candidate. Do not change saved choices during validation. Installation and
recognition accuracy require separate acceptance evidence.

## Consequences

Deepgram Auto now sends an explicit multilingual parameter. Known unsupported
combinations and unknown-model Auto fail early. Supporting newly published
models or additional Auto languages requires updating the verified capability
table and corresponding tests; it is not inferred from model-name prefixes.

## Supersedes / superseded by

Replaces the former Auto-as-parameter-omission behavior. The 2026-10-18
provider-batch decision's provider ownership and no-fallback rules remain;
`detect_language` remains excluded with the model-substitution rationale
recorded here. No later superseding decision is recorded.
