---
id: claude-desktop-binary-layout
type: decision
title: Find the Claude desktop app's Claude Code in both folder layouts
summary: ClaudeBinaryLocator accepts the flat and the hash-folder layout of the desktop app's copy, picks the numerically newest version with a stable tie-break and ignores entries that are not executable files.
status: confirmed
tags: [case, claude-code, agents, locator, desktop]
canonical_for: [claude-binary-detection]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user decided Case → Connect offers Claude Code again so a new user of the Claude desktop app can connect it there (PR #174); this change makes that desktop-only Mac detectable.
    confirmed_at: 2026-10-21
  - type: trace
    reference: Maintainer's Mac, Claude/claude-code under Application Support holds 2.1.299/4fa9694b7975/claude.app and 2.1.304/6bbba6adc37f/claude.app; the binary is a regular executable file signed com.anthropic.claude-code by team Q6L2SF6YDW and answers `--version` with "2.1.304 (Claude Code)".
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/ClaudeBinaryLocator.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/ClaudeBinaryLocatorTests.swift
    confirmed_at: 2026-10-21
related: [2026-10-21-case-connect-claude-code.md]
---

## Context

The Claude desktop app keeps its own auto-updated Claude Code under
`Claude/claude-code/` in the user's Application Support folder. The locator
expected `<version>/claude.app/Contents/MacOS/claude`; current desktop builds
(2.1.299 and 2.1.304 seen) put the app one folder deeper,
`<version>/<hash>/claude.app/...`. A Mac with only the desktop app and no CLI in
the fixed paths or the login-shell PATH therefore found no Claude Code, so
Case → Connect could not offer it.

## Decision

Each version folder is checked for the flat layout and for `claude.app` inside
every child folder. The newest version wins, compared numerically
(`2.1.304` > `2.1.99`). Two copies of one version (two hash folders, or flat
and nested together) are ordered by path, so the result never depends on the
directory listing order. Only executable regular files count: a directory
passes `access(X_OK)`, so it is excluded explicitly; symlinks are followed, so
`~/.local/bin/claude` from the native installer still counts. The home folder
is injectable so tests use a temporary one.

The existing preference between the desktop copy and a legacy CLI is
unchanged: the desktop copy wins unless the legacy binary's `--version` is
strictly newer.

## Rationale

The hash folder is the desktop app's own storage detail and can change again,
so the locator does not depend on the hash format, only on the version folder
name and the `claude.app` bundle path. Within one version, either copy is the
same release, so a stable path order is enough; the binary's modification date
would add a file read without a better answer.

## What was tested

Locator tests on a temporary home with real files: nested only, flat only,
versions across both layouts where lexical order would be wrong, several hashes
of one version in forward and reversed listing order, decoys (non-executable
file, a directory named `claude`, a hash folder without an app, a non-version
folder), an empty and a hash-only tree, desktop against an older and a newer
legacy CLI, and a symlinked legacy install.

No live app check: feature sessions must not launch the app.

## Alternatives rejected

- Search the whole `claude-code` tree recursively: slower and could pick a
  binary from an unrelated nested bundle.
- Prefer the newest modification date within a version: no benefit for one
  release and harder to reason about.
- Ask a login shell only: the desktop copy is never on PATH.

## Supersedes / superseded by

Extends the desktop-managed lookup added for the agent CLI; resolves the known
limit recorded by PR #174 (Case Connect: offer Claude Code again).

The builder verified that executable permission alone also accepts a FIFO. The final regular-file check follows symlinks before checking the target type; a real-file fixture rejects an executable FIFO without launching it. [Case access policy](../../docs/decisions/2026-10-20-case-connect-and-scope.md) is unchanged.
