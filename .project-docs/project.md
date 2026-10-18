---
id: whytap-project
type: project
title: Exodia desktop application
summary: Native macOS voice input, meeting notes, local project knowledge and a customizable local agent workspace.
status: confirmed
tags: [macos, swift, dictation, meetings, agent]
canonical_for: [project-overview]
verified_at: 2026-10-17
sources:
  - type: repository
    reference: README.md
    confirmed_at: 2026-09-07
  - type: repository
    reference: Sources/Sidekey/PostProcessor.swift
    confirmed_at: 2026-09-07
related: [decisions/2026-10-18-clipboard-retention.md, decisions/2026-10-18-toolbox-drag-feedback.md, decisions/2026-10-17-community-updates.md, decisions/2026-10-17-source-first-distribution.md, decisions/2026-10-17-hover-tool-search.md, decisions/2026-10-17-exodia-name.md, decisions/2026-10-17-native-hover-glass.md, decisions/2026-09-07-smart-latency.md, decisions/2026-09-07-codex-model-registry.md, decisions/2026-09-07-soniox-meeting-files.md, decisions/2026-09-08-transcript-copy.md, decisions/2026-09-10-byok-and-local-builds.md, decisions/2026-09-10-onboarding-models.md, decisions/2026-09-10-public-installation.md, decisions/2026-10-17-local-workspace.md]
---

# Exodia

Exodia (formerly Whytap) provides native macOS dictation, meeting notes, and integration with
local agent CLIs. The product presents the user's provider keys (BYOK) first, followed by
on-device models. Architecture and build instructions live in `agent-context.md` and
`../docs/build-and-release.md`.

The existing `../docs/` records remain the entrypoints for historical decisions.
New reasoning-policy and finalization behavior is recorded in
[the Smart latency decision](decisions/2026-09-07-smart-latency.md).

Build and publication policy: [local builds](decisions/2026-09-10-byok-and-local-builds.md).

Launch opens the island directly; setup lives in Settings. Project folders,
notes and a lexical source index stay local. Current scope and limits:
[local workspace and direct launch](decisions/2026-10-17-local-workspace.md).

Coding harnesses share the [source customization workflow](../docs/customization/README.md).

Distribution: [community binaries and updates without Apple Developer](decisions/2026-10-17-community-updates.md), with source builds retained for customizations.
The earlier [Apple-notarized DMG policy](decisions/2026-09-10-public-installation.md)
is historical; runtime installation and resource checks remain current.

Hover uses [three-column native-glass capsules](decisions/2026-10-17-native-hover-glass.md),
with current status inside each control and a legacy material on older macOS.
The current development candidate follows the user's 2026-10-17 correction:
smaller capsules in a drawer matching the actual compact island width.
Monitor opens its dashboard picker inside the same hover drawer; see
[dashboard contracts](../docs/customization/dashboards.md).

Public source: [AbsoluteMode/exodia](https://github.com/AbsoluteMode/exodia).
Naming and storage compatibility: [Exodia rename](decisions/2026-10-17-exodia-name.md).

Hover search launches any catalog tool without adding it to the user's saved
buttons: [tool search](decisions/2026-10-17-hover-tool-search.md).

Clipboard retention: [bounded local history survives restarts](decisions/2026-10-18-clipboard-retention.md).
