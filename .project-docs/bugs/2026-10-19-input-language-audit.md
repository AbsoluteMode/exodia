---
id: input-language-audit-2026-10-19
type: bug
title: Provider input language audit and implemented Deepgram corrections
summary: Selected input language reaches every speech adapter; the source candidate corrects Deepgram Auto and rejects unsupported language combinations, while Retry language changes remain a product decision.
status: observed
tags: [speech, input-language, soniox, deepgram, elevenlabs, realtime, batch, retry]
canonical_for: [provider-input-language-audit]
verified_at: 2026-10-19
sources:
  - type: commit
    reference: b112b44775910eb07f98ba9dcf3ce2e425d23140
    confirmed_at: 2026-10-19
  - type: user-confirmed
    reference: 2026-10-19 Drop troubleshooting chat request to independently audit whether input language reaches Soniox and the other speech providers.
    confirmed_at: 2026-10-19
  - type: user-confirmed
    reference: 2026-10-19 follow-up request to fix the audited issues, including Deepgram Auto.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/DeepgramLanguagePolicy.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsModelsView.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsModelsViewModel.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/TranscriptionSessionFactory.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/AppDelegate.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Privacy/AppLanguage.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Tests/SidekeyTests/Streaming/BYOK/ProviderBatchTranscriberTests.swift
    confirmed_at: 2026-10-19
  - type: url
    reference: https://soniox.com/docs/stt/concepts/language-hints
    confirmed_at: 2026-10-19
  - type: url
    reference: https://soniox.com/docs/stt/concepts/language-restrictions
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developers.deepgram.com/docs/language
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developers.deepgram.com/docs/language-detection
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developers.deepgram.com/docs/models-languages-overview
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developers.deepgram.com/docs/multilingual-code-switching
    confirmed_at: 2026-10-19
  - type: url
    reference: https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
    confirmed_at: 2026-10-19
  - type: url
    reference: https://elevenlabs.io/docs/api-reference/speech-to-text/convert
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developers.openai.com/api/reference/resources/realtime/subresources/transcription_sessions/methods/create
    confirmed_at: 2026-10-19
related: [../project.md, ../decisions/2026-10-19-deepgram-language-policy.md]
---

# Input language audit

## Scope and verified behavior

The initial read-only review of commit `b112b44` covered Settings and hover selection,
Drop realtime and batch recovery, Retry, agent voice, Google voice and
meeting transcription. The subsequent source candidate implements the two
Deepgram corrections below. No application, permission, saved provider
selection or credential was changed by this audit and implementation work.
Installed-app acceptance remains separate from source implementation.

Settings and hover write `PrivacyPreferences.selectedLanguage`; Auto is
`nil`. `targetLanguage` is the separate Smart output-language preference.
`TranscriptionSessionFactory.make(language:)` forwards the selected ISO code
to the adapter. Agent and Google realtime voice share this factory.

For an explicitly selected Russian input, the inspected requests contain:

| Provider | Realtime | Batch recovery / recorder fallback |
| --- | --- | --- |
| Soniox | `language_hints: ["ru", "en"]` | `language_hints: ["ru", "en"]` |
| Deepgram | query `language=ru` | query `language=ru` |
| ElevenLabs | query `language_code=ru` | multipart `language_code=ru` |
| Self-hosted OpenAI-compatible | `session.audio.input.transcription.language: "ru"` | multipart `language=ru` |

Soniox hints are deliberately soft, and the dictation paths deliberately add
English. The parameter reaches Soniox; it does not restrict recognition to
Russian. Auto currently sends the soft hint `["en"]`, retaining automatic
recognition of other languages with an English bias. No strict flag is sent.
The official hints documentation describes this distinction; strict behavior
would require `language_hints_strict=true` and remains best effort.

ElevenLabs and self-hosted Auto omit the language field. This agrees with the
documented ElevenLabs automatic detection and the inspected compatible
request shape. A custom server's implementation was not live-tested.

Meetings use the same saved input preference. Soniox's file API receives only
the selected language as a hint, or no hints for Auto. Other meeting providers
receive the code through their realtime adapters. The finalization manifest
captures language at Stop and reuses it after restart. No input/output
language substitution was found.

## P2 implemented in source: Deepgram Auto defaulted to English

The audited commit omitted `language` for Auto in `DeepgramBYOKAdapter` and
`ProviderBatchTranscriber`. Deepgram documents `language=en` as the default,
so these requests did not enable automatic language recognition. The original
reproduction was Deepgram, Auto, Russian dictation: the request had
`model=nova-3` with neither `language=multi` nor batch language detection.

The former Deepgram Auto tests asserted omission and preserved this behavior.
The provider-batch decision dated 2026-10-18 explicitly rejected
batch `detect_language` to preserve parity with realtime. That explains the
choice; it does not establish that either request implements Auto.

The candidate now shares `DeepgramLanguagePolicy` between realtime and batch:
Auto explicitly sends `language=multi` for the documented supported Nova
models. Explicit `ru` and `en` remain unchanged. Unknown saved models cannot
guess Auto and fail before a socket or upload; an explicit input language can
still reach an unknown/custom model without model substitution. The Models
connection probe uses the current input language, so it does not incorrectly
test an explicitly configured custom model as Auto.

## P2 implemented in source: picker languages exceeded Deepgram support

`Privacy/AppLanguage.swift` builds the shared menu from the Soniox language
set. In the audited commit, Settings and hover did not validate the provider.
For example, `az`, `cy`, `gl`, `ml` and `sw` are offered but are absent from
Deepgram's published Nova-3 language table.

The candidate rejects unsupported explicit languages for the known Nova
models before transport creation or audio upload. The factory wraps this as a
configuration error, which the existing Drop setup path routes to Models.
Models displays the selected model's actual Auto coverage, provides a
supported input-language menu and warns about an incompatible saved language.
It shows the actual saved model instead of a default label; changing it to
Nova-3 requires an explicit button action and Save. A saved input language,
provider or model is never changed by validation. The shared hover menu keeps
its existing full catalog, but an unsupported combination cannot start a
Deepgram take. Details and model limits are in the
[language-policy decision](../decisions/2026-10-19-deepgram-language-policy.md).

## Conditional P3: language can change before recovery or Retry

Realtime sessions retain their input language. Drop's recorder fallback,
delivery resolver and batch recovery instead reread the current preference
in `AppDelegate`'s recorder fallback, delivery resolver and `recoverViaBatch`.
Retained PCM stores its target but no input language. If a take starts with Russian, fails, and the user
selects English before Retry, the retried speech request receives English.
Agent batch voice also reads the preference after recording.

This is not a missing parameter during ordinary use with unchanged settings.
Whether Retry preserves the original selection or deliberately applies a
corrected selection is an unresolved product decision. Meetings already pin
their language at Stop for restart recovery.

## Recommendations, not implemented

- If Retry must preserve language, retain it with the take and PCM and use
  that value in all recovery closures. Test `ru` take, preference change to
  `en`, then Retry. Do not enable Soniox strict mode without a separate
  decision about mixed-language speech and the intentional English hint.

## Verification and limits

On 2026-10-19, `swift test --skip-build` ran the existing mock-based suites
`SonioxBYOKAdapterTests`, `DeepgramBYOKAdapterTests`,
`ElevenLabsBYOKAdapterTests`, `OpenAIRealtimeAdapterTests`,
`ProviderBatchTranscriberTests` and `TranscriptionSessionFactoryTests`:
57 tests, zero failures. That was the pre-correction baseline, reused the
existing test bundle and did not perform a fresh full build. Code and
official provider documentation were also inspected directly.

New policy, request and factory tests cover exact Auto coverage, unchanged
explicit input, unsupported languages, unknown models and rejection before
transport/upload. Source syntax parsing, the policy's standalone typecheck
and whitespace checks passed. A fresh integrated test run and build are
owned by the main task; no new result is claimed in this record yet.

No real audio, dictated text or credentials were submitted to providers.
The checks establish local routing and request serialization, not installed
application acceptance, recognition accuracy, latency, provider-account
availability or compatibility with an arbitrary self-hosted server. The two
P2 corrections are implemented in the source candidate, with installation
and live acceptance not established by this record. The conditional P3
behavior was not changed.

Post-implementation candidate verification: complete Swift suite 2,935 tests, 5 skipped, zero failures. Provider API recognition quality remains a separate live check.
