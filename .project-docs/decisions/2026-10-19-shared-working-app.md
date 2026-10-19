---
id: exodia-shared-working-app-2026-10-19
type: decision
title: Parallel feature sessions feed one identifiable working Exodia
summary: Keep the installed production identity, integrate checked features through main under one writer and report the actual running build and its acceptance checklist.
status: confirmed
tags: [development, agents, integration, main, identity, worktrees]
canonical_for: [shared-working-app-policy]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: On 2026-10-19 the user approved regular integration of checked features into main, requested persistent parallel-development instructions, and required consultation with Gemini and Claude Code because individual sessions had left the running build and acceptance scope unclear.
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/dev-run.sh
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/BuildConfig.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Updates/UpdateController.swift
    confirmed_at: 2026-10-19
  - type: trace
    reference: Claude Code consultation f5197223-847c-4567-8918-e8b07c33ab93 and reconciliation 72df1dc1-548c-4438-90ff-97b4192103e2; Gemini conversation 2cc05a31-563b-4135-96b7-3705be1e405e, explicit agreement recovered despite interrupted-stream job status.
    confirmed_at: 2026-10-19
related: [2026-10-19-one-running-copy.md, ../project.md, ../processes/shared-app-development.md, 2026-10-19-build-queue.md]
---

# One shared working application

## Context

Several coding sessions each develop a feature. Launching their worktree apps
leaves the user unsure which features are present or what needs checking.
In main at the time of this decision, the dev packaging helper creates the same
beta identity in each worktree and can stop another beta process even without
`--run`. Production and beta use different credential/settings buckets while
sharing some user stores, including meetings and clipboard history.
Switching the user's working app to beta would introduce another identity.

## Alternatives

- Continue accepting each feature in its separate app: retains the confusion
  and process/registration interference the user asked to remove.
- Let every session overwrite the installed app: creates concurrent writers
  and exposes unfinished or mutually incompatible feature combinations.
- Keep parallel worktrees and serialize checked integration into one installed
  app: preserves parallel development and gives acceptance one clear target.

## Decision and rationale

Use the third alternative. Keep `/Applications/Exodia.app` with its production
identity and existing storage/signing identity. Ready features enter main
through reviewed, locally validated PRs. Any session can become integrator,
but shared refs, receipts and app replacement have one repository-wide writer.
Routine integration/local refresh is authorized; publication remains separate.

The [procedure](../processes/shared-app-development.md) owns exact actions.
It separates source merge, candidate preparation and verified app promotion;
requires an explicit running-build receipt and acceptance checklist; preserves
WIP and a compatible rollback bundle; and defers installation during active or
unknown work. In-process identity takes precedence over mutable on-disk metadata.
Only one app may run across all channels because some stores and hotkeys are
shared. Candidate promotion verifies signing identity/designated requirement
and monotonic version/build ordering against the installed application.

## Sources and verification

The dated user request establishes the workflow requirement. Repository checks
establish the dev packaging side effects, channel separation and Sparkle's
activity guard. That guard protects Sparkle, not an external installer. Existing
feature-branch tools may improve this, but are not treated as merged main code.
The installed app must be inventoried before the first main-based promotion so
that branch-only fixes already in use are preserved.

Codex reconciled independent Gemini and Claude Code proposals against repository
evidence. Both accepted this process after correction of unsupported claims
about main protection, signing, activity detection and branch differences.
Gemini returned explicit agreement, but its connector marked the stream
interrupted; the recovered response is discussion evidence, not a completed
runtime verification. Claude Code's reconciliation completed successfully.

## Comments and objections

The user wants feature interactions reported and resolved between agents.
Ordinary textual merge conflicts do not need a new user decision. Incompatible
product behavior, destructive changes or an otherwise unresolved risk do.
Instructions alone do not make dormant sessions or external scripts cooperate.

## Resolution and consequences

Persist the policy in canonical agent guidance and synchronize both harness
entry files. Existing sessions reread current main before app/integration
actions. Runtime guardrails, a lightweight production staging command and
automatic receipt generation can be implemented as focused follow-up work;
this documentation change does not claim those protections already exist.

## Supersedes / superseded by

For the maintainer's parallel sessions this replaces ad-hoc worktree app
launches with the shared-app procedure. Standalone source builds and public
release provenance/signature/acceptance gates keep their existing contracts.

The later [build queue decision](2026-10-19-build-queue.md) replaces permission
for every feature session to become integrator with one designated builder and
automatic FIFO submissions. The remaining shared-app safeguards still apply.
