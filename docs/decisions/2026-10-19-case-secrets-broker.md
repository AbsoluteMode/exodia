---
id: whytap-case-secrets-broker-2026-10-19
type: decision
title: Case secrets broker lets AI clients use keys without seeing values
summary: Names-only MCP, a CLI run inside the AI's own terminal, a Unix-socket broker that identifies the caller by process chain, values only in the child's environment.
status: confirmed
tags: [case, secrets, mcp, broker, security]
canonical_for: [case-ai-access]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: Design approved with Maxim in docs/superpowers/specs/2026-10-19-case-secrets-manager-design.md (2026-10-19).
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Case/Broker/CaseBroker.swift
    confirmed_at: 2026-10-19
related: []
---

# Case secrets broker

## Context

AI assistants (Claude Code, Codex, Cursor, the built-in agent) read secrets by
running commands such as `doppler secrets get NAME --plain`. The value lands in
the transcript, which goes to the model provider and the team recall hub. Case
already stores keys encrypted with Touch ID; it had to let an AI use a key
without ever receiving its value.

## Decision

- **Names-only MCP.** `whytap case mcp` (stdio) offers `case_list_projects` and
  `case_list_keys`: project names, key names and plain-text descriptions only.
  There is no run-command tool and no tool that returns a value.
- **Run through the AI's own terminal.** `whytap case run [-p project]
  [--only A,B] '<command>'` is executed by the AI in its normal shell, so its
  sandbox and permission rules still apply. The helper asks the app's broker
  for values, starts `/bin/sh -c <command>` and puts the values **only in the
  child's environment**, never argv (argv is visible to every process through
  `ps`; the environment is not, verified on this Mac). stdout and stderr go
  through the masker.
- **Broker in the app.** A Unix socket in Application Support (directory 0700,
  socket 0600, `cb.sock` fallback for long home paths). No network, no XPC.
- **Helper check.** The app accepts a peer only if its audit token
  (`LOCAL_PEERTOKEN`) resolves to the bundled `Contents/Helpers/whytap` by
  **cdhash**, which works for ad-hoc community signing as well. An untrusted
  peer gets `.untrustedHelper` before one byte of its request is read.
- **Caller identity by process chain.** The broker walks the helper's parent
  chain and takes the nearest registered or known AI app. Claude Code and Codex
  are matched by Developer ID team ID plus signing identifier, but a team ID is
  trusted only after the code is proven Apple-anchored (an ad-hoc binary can
  claim any team ID string). Others are matched by registered path on a `/`
  boundary. A broken chain, a cycle, more than 32 hops or no AI app means a
  person at a terminal: Touch ID. A known but unregistered AI is refused with a
  hint; the built-in OpenCode agent is refused unless registered.
- **Modes.** Each registered app is Approve or Bypass, with optional per-project
  override. Approve shows a prompt under the island: Y allow once, N/Escape
  deny, A allow this app and project for N minutes (default 15, memory only,
  cleared on restart). Keys are matched by physical key code so they work on any
  layout; for 300 ms after appearing nothing is accepted, 60 s denies, requests
  queue. `CaseApprovalKeyTap` exists only while a prompt is queued and swallows
  only those four keys (see docs/hotkey.md).
- **Registration** also writes the MCP entry into the client's own config
  (`claude mcp add -s user`, `codex mcp add`, `~/.cursor/mcp.json`, the built-in
  OpenCode config) with the absolute helper path (GUI-launched agents often lack
  `~/.local/bin` on PATH). No secret is ever written there.
- **Masking.** Exact value, base64 (three shifts, standard and URL-safe), hex
  (both cases), URL and JSON escaping, multi-line values whole and per line,
  with a carry-over buffer across chunk boundaries. Values shorter than 4 bytes
  are not masked and the UI says so. MCP output is never masked-wrapped.

## Why

- A run-command MCP tool would move execution out of the AI's sandbox and
  permission rules into Whytap and make Whytap the thing that runs arbitrary
  code. Running in the AI's terminal keeps their controls in force.
- Values in argv or MCP responses leak to `ps`, transcripts and config files;
  the environment of a child does not.
- Process-chain identification needs no per-client protocol, works for every
  terminal AI, and lets the user register a program once.
- Apple-anchored team IDs: otherwise any binary could name itself "Anthropic".
- cdhash pinning means a copy of the helper elsewhere, or a swapped binary, is
  not served.
- The decrypted payload stays in memory beyond the 15-minute idle lock of the
  island UI because the broker must answer while the UI is locked; it is
  released on quit and on reset. Touch ID is still asked for any human use.

## Threat model and masking limits

Case protects against **accidental** leaks of values into transcripts and
against unregistered programs. It does not protect against an AI that
deliberately extracts a value (reverse the string, write it to a file and read
it back, split it across lines), nor against malicious code running as the same
user; everything an approved AI runs in its terminal (including npm scripts)
acts with its rights. This is the same boundary as Doppler CLI and `op run`.
Masking is best effort and bytes-based; it is not a security boundary.

## What we tested

- Broker end to end over a real socket with fake inspector/resolver: untrusted
  helper, stuck and oversized clients, garbage lines, stale socket replacement,
  refusal to replace a regular file, concurrent connection cap.
- Caller resolution with fake process trees: Apple-anchor refusal, cycles,
  hop limit, path boundary, unregistered known AI.
- Masker: every encoding variant, chunk-boundary splits, multi-line values.
- Flaky test found in the final run: `test_untrusted_helper_rejected` failed
  under full-suite load with `CaseBrokerClientError 1`. Cause: the server wrote
  the denial and closed without reading the request; on BSD, closing a socket
  with unread inbound bytes sends RST, which discards the reply still queued
  for the client. Fixed in `CaseBrokerServer` with a lingering close
  (`shutdown(SHUT_WR)` then a bounded drain), not with retries. 5 consecutive
  runs of `CaseBrokerTests` plus the full suite pass.
- Packaging contract test: both build scripts build, copy and sign
  `Contents/Helpers/whytap` before the app signature.
- Not run live (feature sessions may not launch an app): real `claude`/`codex`
  CLIs, Touch ID, the NSOpenPanel from the island, the prompt keys and Russian
  layout, the packaged helper's cdhash trust path, OpenCode's MCP entry and
  permission wildcard. These need acceptance by the integrator.

## Rejected

- Run-command MCP tool: moves execution out of the AI's sandbox.
- Values in MCP responses (Doppler's approach): ends up in the transcript.
- Values or tokens in argv or in client config: visible to `ps` or to files.
- XPC instead of a socket: no gain for a user-local helper; socket kept.
- Command named `case`: reserved word in zsh/bash; `whytap` is free.
- Trusting a team ID without an Apple anchor.
- Ad-hoc masking wrapper around MCP stdio: breaks the MCP protocol.
- Logging an audit trail of AI uses: explicitly out of scope for v1.

## Implementer rulings (from the build ledger)

- Task 0: origin was re-pointed (exodia to whytap); the app refuses sync as a
  security check. Maxim re-pinned and gave an explicit go-ahead before the
  manual merge of origin/main.
- Ruling 2: `CaseBrokerCalling` and `UnixSocketBrokerClient` live in
  `WhytapCaseKit` so the MCP server can use them.
- Ruling 3: the CLI derives its bundle ID from the enclosing app
  (`Contents/Helpers/whytap` to `../Info.plist`), not from compile defines.
- Ruling 4: removed the hover `.ended` drag reset; it can fire mid-drag and
  cancel a header drop. Cost if wrong: stuck autoscroll until reopen.
- Ruling 5: MCP instructions use the helper's absolute path.
- Task 8: walk starts at the peer's parent; broken chain, cycle or over 32 hops
  falls back to human; path match on `/` boundary. Risk: pid reuse mid-walk.
- Task 9: listing needs Touch ID; `unknownProject`/`unknownKey` answered to a
  person without Touch ID (reveals only existence of names); project match is
  exact first, else a single case-insensitive match; 0-minute grant means none;
  malformed or timed-out requests are closed without a reply.
- Task 10: the prompt is a separate non-activating panel flush under the island.
- Task 11: Touch ID required only when a change can open Bypass; the CLI symlink
  is reinstalled on every registration; a missing helper leaves the registration
  standing without client config; with actions off the built-in agent gets only
  the `case_*` listing tools.
- Deferred minors: v1 `.bak` is kept only until the second save; migrated
  project names deduped before 48-char truncation can collide; the socket path
  can exceed 104 bytes for a very long home; the prompt overlaps the top of an
  agent answer card; Russian labels vs English errors (ask Maxim); rewrites of
  `~/.claude/settings.json` and `~/.cursor/mcp.json` re-sort keys (content kept,
  `.bak` saved); built-in OpenCode PIDs depend on process plumbing.

2026-10-19. Commits: 0fee034..225df91 on branch claude/sad-nobel-2aaef9, final
packaging and docs commit follows.
