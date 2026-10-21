---
id: case-connect-claude-code
type: decision
title: Case Connect offers Claude Code again
summary: The Connect catalog is OpenCode, Claude Code and Cursor; Codex stays a legacy registration only.
status: confirmed
tags: [case, secrets, agents, connect, claude-code]
canonical_for: [case-connect-catalog]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user decided to offer Claude Code in Case → Connect again so a new user can connect the Claude desktop app's Claude Code there, without adding Codex.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Case/Clients/CaseClientSetup.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Case/Clients/CaseClientConnector.swift
    confirmed_at: 2026-10-21
related: []
---

# Case Connect offers Claude Code again

## Context

PR #119 (Case Connect: OpenCode and Cursor logos with grouped rights) narrowed
`CaseKnownClient.connectableClients` to OpenCode and Cursor. Claude Code and
Codex remained only as legacy registrations that stay editable from their
icons. A new user with the Claude desktop app therefore had no way to connect
its Claude Code to Case, which the user also needs for the product video.

## Decision

The Connect catalog is `[.builtInOpenCode, .claudeCode, .cursor]`, in that
order. Claude Code appears only when `ClaudeBinaryLocator` finds the CLI and it
is not registered yet. Codex is not offered. Nothing else changes: the existing
connector runs `claude mcp add -s user case -- <helper> case mcp`, the broker
identity, the bundled `claude-code` brand mark and the orange highlight are
reused; no new asset is added. The empty picker now names all three clients.

## Rationale

Everything Claude Code needs at the broker and client boundary already exists
and is tested; only the catalog filter hid it. Returning it is a one-line,
reversible change that keeps every legacy registration and right unchanged.
Codex stays out because the user asked only for Claude Code.

## What was tested

- Discovery over all eight installed/absent combinations of OpenCode, Claude
  Code and Cursor with an installed Codex: only installed offered clients are
  returned, in catalog order, with no command run and no file written.
- The picker offers Claude Code when installed and unregistered, hides it when
  not installed or already registered, never offers Codex and changes no
  saved rights.
- Every Connect row resolves to a bundled brand mark with visible artwork at
  22 pt; picker renders at 310/390 pt include a Claude Code row.

No live app check: feature sessions must not launch the app.

## Known limit

`ClaudeBinaryLocator` looks for the desktop app's copy at
`Claude/claude-code/<version>/claude.app`, but current Claude desktop builds
(2.1.299, 2.1.304 on the maintainer's Mac) add a hash directory:
`<version>/<hash>/claude.app`. A Mac with only the desktop app and no `claude`
in the known paths or login-shell PATH is therefore not detected yet, so Connect
does not offer Claude Code there. The desktop copy is signed
`com.anthropic.claude-code` by team `Q6L2SF6YDW`, matching the broker identity.
Extending the locator is a separate follow-up because ClaudeCodeProvider and the
agent setup checklist share it.

## Alternatives rejected

- Keep the narrowed catalog and show Claude Code only as a legacy
  registration: new users could not connect it at all.
- Return Codex as well: not requested.
- Ship a separate Claude Code picker logo: the bundled `claude-code` mark
  already renders in the picker.

## Supersedes / superseded by

Amends the Connect catalog of PR #119 and
[Case Connect and scope](../../docs/decisions/2026-10-20-case-connect-and-scope.md);
scope, modes and broker checks are unchanged.

Implementation references: [Case broker](../../docs/decisions/2026-10-19-case-secrets-broker.md), [design](../../docs/DESIGN.md) and [product spec](../../docs/SPEC.md).
