---
id: feature-costs-2026-10-20
type: decision
title: Feature costs preserve historical models and separate ElevenLabs credits
summary: Four API & Models tabs share one surface; Costs lists used features for a chosen period and reveals historical models on hover, click or keyboard focus.
status: confirmed
tags: [settings, costs, models, credits, providers]
canonical_for: [feature-costs]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 Maxim approved API keys, Models, Costs and API hints, used features only, a nearby period selector and historical models on hover in a unified panel.
    confirmed_at: 2026-10-20
  - type: user-confirmed
    reference: On 2026-10-20 Maxim requested ElevenLabs credits because free and purchased credit allocations do not have a universal dollar conversion.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/AIRouting/AIUsageStore.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/AIUsageCostsView.swift
    confirmed_at: 2026-10-20
  - type: url
    reference: https://openrouter.ai/docs/cookbook/administration/usage-accounting
    confirmed_at: 2026-10-20
  - type: url
    reference: https://soniox.com/pricing
    confirmed_at: 2026-10-20
  - type: url
    reference: https://github.com/elevenlabs/elevenlabs-python/tree/main/src/elevenlabs/workspace/analytics/requests
    confirmed_at: 2026-10-20
  - type: url
    reference: https://github.com/anomalyco/opencode/blob/v1.17.12/packages/opencode/src/session/session.ts
    confirmed_at: 2026-10-20
related: [2026-10-19-api-hints.md]
---

# Feature expenses

The four tabs share one native settings panel. Models remains the initial tab;
runtime repair links select it before expanding the affected feature. API hints
becomes the fourth tab, retaining its offer content and existing add-key form.

Costs shows Today, Last 7 days, This month or Custom dates at the heading. Dates
use the local calendar and include the selected end day. Only feature groups
with activity in that period appear. Hover, click or keyboard focus reveals all
models actually used, grouped by provider and model; Escape closes details.
Paired speech/text routes aggregate into one feature, preserving both models.

The new local `ai-usage.sqlite` stores only timestamps, stable request IDs,
feature/provider/model identifiers, duration, currency, amount and price basis.
It never stores credentials, endpoint URLs, prompts, transcripts, audio or replies.
Routes are captured before the request; later changes cannot rewrite history.
Synthetic model checks are excluded. Tracking starts with this update: there is
no retroactive estimate from current routes or account-wide spending.

USD and ElevenLabs credits are separate columns. OpenRouter `usage.cost` is a
reported expense. Soniox's equivalent hourly rates ($0.12 realtime / $0.10 async
for the supported v5 models) and OpenCode's per-step token/price calculation are
estimates, marked ≈. A partial total uses + for excluded unknown prices; a wholly
unknown price is Unavailable. Failed/interrupted work is not silently free.
OpenCode child-agent costs that are absent from its top-level event stream leave
an incomplete marker rather than a fabricated complete total.

ElevenLabs' official SDK exposes a request analytics endpoint with explicit
column units. The app reads it with the existing key, joins only an exact
request/session ID captured from its own response, verifies the model when
present, and accepts one unambiguous credit column. The same journal entry is
reconciled once. Free and purchased credits remain credits. USD columns,
account-wide balance deltas, ambiguous rows and guessed plan conversions are
never used. Delayed analytics, missing identifiers or insufficient key scope
leave the expense unavailable; reopening Costs retries at a bounded rate.

Offscreen fixtures and stubbed network tests establish layout, attribution and
failure handling. Live analytics availability and identifier correspondence are
not established by those fixtures and remain normal-use acceptance after the
shared-app builder promotes the feature. No paid test request is required.
