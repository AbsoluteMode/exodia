---
id: remove-projects-2026-10-19
type: decision
title: Remove Projects and automatic project context
summary: Remove the project library and its agent integration while retaining existing local data unused.
status: confirmed
tags: [projects, knowledge, agent, removal, privacy]
canonical_for: [project-knowledge-removal]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: On 2026-10-19 the user rejected the Projects behavior and requested its removal for now.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Agent/AgentController.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsWindowTab.swift
    confirmed_at: 2026-10-19
related: [../project.md, 2026-10-17-local-workspace.md]
---

# Remove Projects

## Context

After reviewing what Projects does, the user requested its removal for now.

## Alternatives

Hide only the Settings tab, or remove the entire project-library runtime.
Hiding the tab alone would leave saved project selections feeding requests.

## Decision

Remove the Projects tab, folder scanner, index, notes UI, project evidence and
project-scoped agent routing. The ordinary agent keeps its neutral workspace
and per-provider session store. Leave existing catalogs, indexes and separate
project-agent workspaces on disk without opening, migrating or deleting them.

## Rationale

The removed feature must no longer affect agent requests, including when an
older installation has an active project saved. Retaining local files avoids
unrequested data loss while the feature is withdrawn.

## Sources

The dated user request and implementation files listed in the frontmatter.

## Comments and objections

The user rejected the current feature. No replacement workflow was requested.

## Resolution

Remove the feature rather than adding another setting or a replacement UI.

## Consequences

There is no project folder search, automatic project-note attachment, or
project-scoped session resumption. Ordinary agent requests and memory remain.
Any future project feature requires a new product decision.

## Supersedes / superseded by

Supersedes only the project-library and project-agent portions of
[the local workspace decision](2026-10-17-local-workspace.md).
