---
id: case-connect-and-scope
type: decision
title: Case Connect opens agent rights with explicit project scope
summary: Separate search from writes and store enforceable agent scope with adjustable temporary Bypass.
status: confirmed
tags: [case, secrets, agents, permissions, search, performance]
canonical_for: [case-connect-and-project-scope]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 the user requested Connect, per-agent project selection, Accept or Bypass, adjustable temporary Bypass defaulting to 15 minutes, search separated from key creation and provider-colored hover logos.
    confirmed_at: 2026-10-20
  - type: user-confirmed
    reference: On 2026-10-20 the user clarified that perceived Case/search lag may have been caused by many concurrent builds.
    confirmed_at: 2026-10-20
  - type: user-confirmed
    reference: On 2026-10-20 the user reported that a newly created project could not be found; this corrects the earlier key-only search interpretation.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Case/Broker/CaseBroker.swift
    confirmed_at: 2026-10-20
related: [2026-10-19-case-secrets-broker.md, ../DESIGN.md, ../SPEC.md]
---

# Case Connect and scope

## Context

The old input mixed search and creation. All connected icons led to a common
access list, and project-specific modes did not restrict the set of projects.
The user chose a direct Connect → agent → rights flow and raised possible lag,
then noted simultaneous builds as a possible cause. There is no confirmed
live performance diagnosis.

## Alternatives

Keeping per-project modes alone cannot express denial outside selected projects.
A UI-only filter would leave CLI and MCP unrestricted. Reusing schema 2 with an
ignored extra field would let an older app silently restore unrestricted access.

## Decision

Connect opens installed clients/custom program selection, then a policy draft.
Existing icons open that registration. Save stores mode and scope together.
Accept is the UI label for the existing persisted approve mode. Existing
per-project mode overrides are preserved and remain editable.

Schema 3 adds optional allowedProjectIDs. Missing/nil means all current/future
projects, preserving schema-2 access; an explicit set allows only those projects,
including an empty set that denies every project. Older apps refuse schema 3
with Update required, preserving its data. The broker filters names/ambiguity
before resolution and rechecks current scope before releasing values or grants.
Access changes invalidate that app's temporary grants.

The prompt selects 1–240 minutes for temporary Bypass, default 15. The button
and physical 3 use the displayed duration; the broker validates the range.
The numeric-only answer mapping is recorded in
[numeric approval keys](2026-10-21-case-numeric-approval.md).
The grant covers only the same app/project and remains memory-only. Search
matches projects and keys and their descriptions, including empty projects and
General; adding uses a separate explicit form. Project matches show their full
key list; key-only matches show just the matching keys. Search-result projects
retain the explicit + Key action.

## Rationale

The visible project selection is an authorization boundary. Broadening it and
enabling Bypass require Touch ID, while narrowing it can close access immediately
on save. A newer schema prevents older binaries ignoring the restriction.
Cached names-only metadata removes repeated value scans and repeated project
sorting from typing/rendering without weakening the opening authentication.

## Sources

The user request and current source paths are recorded above. Behavior tests
cover scope filtering, revocation during approval, expiry, schema migration,
registration and search; native fixtures cover composition without app launch.

## Comments and objections

The user cautioned that hardware/build load could explain the lag. Synthetic
benchmarks can compare code paths but cannot establish the cause of that report.

## Resolution

Implement the requested interaction and remove redundant display work. Keep
opening Touch ID and make no claim that the user's live lag was reproduced.
The created-project search report supersedes the original key-only interpretation;
find projects as well as keys while keeping creation explicit.

## Consequences

The first save from this version writes schema 3. Rollback to a schema-2 binary
cannot open it; keep the shared workflow's private pre-migration backup. Never
restore an older vault automatically, because that could lose keys or rights.
No user data or app bundle is changed by feature tests.

## Supersedes / superseded by

Replaces the broker decision's old shared access-list/search composition and
schema version; retains its helper trust, value isolation and approval controls.
