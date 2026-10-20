---
id: feature-costs-2026-10-20
type: decision
title: Feature costs preserve historical models and separate ElevenLabs credits
summary: Costs estimates ElevenLabs feature credits from recorded time and reported model rates, with separate workspace debits grouped by API key for the selected period.
status: confirmed
tags: [settings, costs, models, credits, providers]
canonical_for: [feature-costs]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 Maxim requested verification on existing sessions, approved separate reported usage by API key and directed feature estimates from recorded time with each model.
    confirmed_at: 2026-10-21
  - type: url
    reference: https://elevenlabs.io/docs/api-reference/analytics/workspace/usage
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
From/To use the same neutral control fill as the period menu and open a native
calendar that closes after a changed date, Done/Return or Escape. No selected
text segment remains on the closed control. Feature-row fill follows actual
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

Live verification on 2026-10-21 established that the request log returns request
metadata without credit amounts. Its documented example is not the live billing
schema. The saved session references did not resolve through the usage table's
request/trace filters. The previous exact-request reconciliation is therefore
replaced by the user's approved time calculation.

Costs reads `/v1/workspace/analytics/query/usage-by-product-over-time` for the
selected date interval, grouped by API key, model and product. It validates the
explicit `credits` and `min` column units, accepts numeric strings, and combines
daily rows within each key/model/product. Missing or ambiguous credit columns,
HTTP failures and unreadable keys produce an explanation with Refresh, not zero.
A successful empty table means no reported usage. Reads occur when Costs loads
or refreshes, not after every transcription. Tests and fixtures default to no
real credential or network access.

For an ElevenLabs STT model, reported credits divided by reported minutes gives
an effective credit rate. Each feature's recorded audio minutes times that
model's rate yields an estimate marked ≈. Rates are model-specific and weighted
by reported minutes; other apps' total credits are never distributed among our
features. Different rates, rounding, provider billing time and analytics delay
can affect this estimate. No matching timed model, no usable duration/rate, or
failed analytics means unavailable. Known per-request amounts are retained.
Computed estimates never overwrite historical journal rows as reported debits.

A separate ElevenLabs Reported usage section shows actual workspace charges,
grouped by API key and model, for the same period. It explicitly includes other
apps using this workspace's keys. Authentication does not prove that the response
is limited to the currently stored key, so the UI labels workspace scope. This
section is not added to feature Total: that would count some work twice. Provider
key hashes are transient grouping IDs; credentials, hashes and full responses
are never stored in the journal or diagnostics.

Verification uses synthetic parser/network/multiple-feature fixtures and a
read-only snapshot of the user's existing journal with the production billing
client and estimator. No new inference or journal mutation is needed. Installed
UI acceptance remains separate from this diagnostic and source checks.
