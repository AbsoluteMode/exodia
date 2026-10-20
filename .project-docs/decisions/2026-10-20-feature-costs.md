---
id: feature-costs-2026-10-20
type: decision
title: Feature costs preserve historical models and separate ElevenLabs credits
summary: Costs has one Price column with explicit USD or credit units, defaults to This month and reveals historical models; calendar controls share the period menu appearance.
status: confirmed
tags: [settings, costs, models, credits, providers]
canonical_for: [feature-costs]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 Maxim requested a more convenient Costs calendar, objected to its large blue focus ring and asked how to choose a year.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-20 Maxim requested one Price column, removal of the bottom explanation, This month by default, consistent control fills, no persistent date selection and repair of ElevenLabs credits.
    confirmed_at: 2026-10-20
  - type: url
    reference: https://elevenlabs.io/docs/api-reference/analytics/workspace/requests
    confirmed_at: 2026-10-20
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

Costs shows Today, Last 7 days, This month or Custom dates at the heading. Each
visit starts at This month; custom dates remain selectable within that visit.
From/To use the same neutral control fill as the period menu. As amended on
2026-10-21, their calendar has a month menu and an editable year combo with the
recent 100 years (earlier positive years can be typed). Browsing changes only
the visible month; choosing a day or Today commits and closes. Done/Return and
Escape close without applying a browsed month. Future days and navigation past
the current month are unavailable. Individual controls and days retain visible
keyboard focus, hover and pressed feedback, replacing the native calendar’s
large focus ring. Disabled days never react to hover. No selected text segment
remains on the closed control. Feature-row fill follows actual
pointer hover rather than the lifetime of its detail popover. Dates
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

USD and ElevenLabs credits are distinct values in one **Price** column, each
with its unit. If a feature used both, the cell and Total retain both on separate
lines. The user replaced the earlier two-column design; currencies are never
added or converted. The bottom explanation is removed; estimate/incomplete
marks remain on values and their explanation is available in help/details. OpenRouter `usage.cost` is a
reported expense. Soniox's equivalent hourly rates ($0.12 realtime / $0.10 async
for the supported v5 models) and OpenCode's per-step token/price calculation are
estimates, marked ≈. A partial total uses + for excluded unknown prices; a wholly
unknown price is Unavailable. Failed/interrupted work is not silently free.
OpenCode child-agent costs that are absent from its top-level event stream leave
an incomplete marker rather than a fabricated complete total.

ElevenLabs' official SDK exposes a request analytics endpoint with explicit
column units. The app reads it with the existing key, joins only an exact
request/session ID captured from its own response, verifies the model when
present, and accepts one unambiguous credit column. The documented analytics
response includes numeric strings, which the credit parser accepts without
relaxing inference API parsing. A search result without an ID column cannot
establish attribution; a bounded second query uses an explicit request_id
equality filter and accepts only one matching row. Unsupported filters or
ambiguous responses remain unavailable. The same journal entry is
reconciled once. Free and purchased credits remain credits. USD columns,
account-wide balance deltas, ambiguous rows and guessed plan conversions are
never used. Delayed analytics, missing identifiers or insufficient key scope
leave the expense unavailable; reopening Costs retries at a bounded rate.

Offscreen fixtures and stubbed network tests establish layout, attribution and
failure handling. Live analytics availability and identifier correspondence are
not established by those fixtures and remain normal-use acceptance after the
shared-app builder promotes the feature. No paid test request is required.
