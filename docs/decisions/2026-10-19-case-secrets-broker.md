---
id: whytap-case-secrets-broker-2026-10-19
type: decision
title: Case secrets broker lets AI clients use keys without seeing values
summary: Names-only MCP, a CLI run inside the AI's own terminal, a Unix-socket broker that identifies the caller by process chain, values only in the child's environment.
status: confirmed
tags: [case, secrets, mcp, broker, security]
canonical_for: [case-ai-access]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: Design approved with Maxim in docs/superpowers/specs/2026-10-19-case-secrets-manager-design.md (2026-10-19).
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Case/Broker/CaseBroker.swift
    confirmed_at: 2026-10-19
  - type: user-confirmed
    reference: On 2026-10-20 the user requested a larger Case hover, clearer AI connection wording, copying all Doppler secrets into Case, and a fix for hover closing during Touch ID.
    confirmed_at: 2026-10-20
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
  The entire bundled universal file must validate. Its default native slice
  and explicit arm64/x86_64 slices are queried with the public Security
  architecture selector, so an x86_64 helper running under Rosetta matches
  its signed slice rather than the broker's preferred native slice. A missing
  slice never authorizes a peer. Audit-token lookup and live-code validity
  remain mandatory; matching an identifier alone is insufficient.
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
  cleared on restart, not on the panel's idle lock because the broker keeps
  serving then). Keys are matched by physical key code so they work on any
  layout. **Arming:** a prompt accepts nothing until the keyboard has been
  quiet for 300 ms; every key press the tap sees while it is unarmed starts
  the wait again, so someone typing in another app can never answer it.
  60 s denies (typing does not extend it), requests queue. A prompt whose
  client disconnects (Ctrl-C, a killed agent) is withdrawn and denied, and
  no timed grant is made for it. After an A answer, prompts already waiting
  for the same app and project are allowed by that grant instead of shown.
  The prompt sits under the agent answer card when both are visible (the
  built-in agent running `whytap case run`). `CaseApprovalKeyTap` exists only
  while a prompt is queued and swallows only those four keys (see
  docs/hotkey.md).
- **Revocation while waiting.** After Touch ID or an approval answer, the
  broker resolves the peer again and requires the same principal and current
  registration UUID/identity before releasing values. Removing a registration,
  replacing its identity or registering it again with a new UUID invalidates
  the pending request, including queued requests resumed by a timed answer.
  The current project and approved key IDs must still exist. A timed grant is
  created only after these checks and successful value resolution, with no
  suspension between validation, grant creation and release on the main actor.
- **Touch ID text** for a person's `whytap case run` names the nearest app in
  the helper's parent chain (Terminal, iTerm2…) or "неизвестный процесс" when
  the walk reaches pid 1 without one (ssh, cron, a launchd job), and the
  command on one line, whitespace collapsed, at most 80 characters with the
  middle cut. It never contains a value.
- **Names are unique.** The broker refuses (never picks) when a project
  holds two keys with one name or two projects share a name. A backup merge
  renames a clashing incoming project to `name (2)` and key to `NAME_2`, the
  same suffixes migration uses; names already on this Mac are kept. Migration
  dedupes project names after truncation to 48 characters.
- **Schema-1 copy.** The first time a schema-1 vault is saved as schema 2 the
  old file is copied once to `case-vault.json.enc.v1` (0600, created
  exclusively, never overwritten); `.bak` alone held the v1 bytes only until
  the second save.
- **Registration** also writes the MCP entry into the client's own config
  (`claude mcp add -s user`, `codex mcp add`, `${HOME}/.cursor/mcp.json`, the built-in
  OpenCode config) with the absolute helper path (GUI-launched agents often lack
  `${HOME}/.local/bin` on PATH). No secret is ever written there. An existing MCP
  server named `case` that is not a `whytap`/`whytap-*` helper serving
  `case mcp` is reported as a conflict and never replaced or removed. JSON
  configs that are symlinks (dotfiles repos) are written through the link: the
  real file is replaced atomically, keeps its permission bits and is backed up
  as `<real file>.bak`; the link stays a link.
- **Masking.** Exact value, base64 (three shifts, standard and URL-safe), hex
  (both cases), URL and JSON escaping, multi-line values whole and per line,
  with a carry-over buffer across chunk boundaries. Only the end of the output
  that is the beginning of some variant is held back; everything else is
  written at once, so a dev server's "listening" line or a `[y/N]` prompt
  appears immediately (holding a fixed longest-variant tail hid them). Values
  shorter than 4 bytes are not masked and their row says «не скрываются в
  выводе». MCP output is never masked-wrapped.
- **CLI options** `-p` and `--only` are read only before the command:
  `whytap case run grep --only x f` passes `--only x` to grep.

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

Built-in OpenCode commands inherit Whytap's TCC responsibility: macOS
attributes a process to the app that started it, and Whytap starts OpenCode,
so a command the built-in agent runs (including `whytap case run`) uses the
privacy grants Whytap holds (microphone, accessibility, files the user allowed
Whytap to read). This predates Case and Case does not widen it: the values
still reach only the child of the helper, never the app process, and the
broker treats the built-in agent like any other registered app. External
clients (Claude Code, Codex, Cursor) run under their own TCC identity.

A restored backup brings back its app registrations, Bypass included, without
Touch ID (see docs/backup.md); a backup someone else made should be reviewed
in Case -> access after restoring.

Case protects against **accidental** leaks of values into transcripts and
against unregistered programs. It does not protect against an AI that
deliberately extracts a value (reverse the string, write it to a file and read
it back, split it across lines), nor against malicious code running as the same
user; everything an approved AI runs in its terminal (including npm scripts)
acts with its rights. This is the same boundary as Doppler CLI and `op run`.
Masking is best effort and bytes-based; it is not a security boundary.

## What we tested

- Real signed universal socket-client fixtures (2026-10-20), using actual
  `LOCAL_PEERTOKEN` and the production inspector: native and Rosetta accepted;
  a different validly signed binary with the same identifier, a tampered
  universal file and an invalid audit identity denied. These use disposable
  local sockets and synthetic binaries without a vault, client configuration,
  app launch or Touch ID. Before the fix the Rosetta positive failed, and a
  native peer could pass when only the inactive bundled slice was corrupted.
- Revocation regressions (2026-10-20): removal during Allow and timed Allow,
  identity replacement, a changed peer, and real approval-controller queued
  requests all deny values without creating a grant. Deleted projects/keys
  also create no grant. Human Touch ID revalidates before run, listing and
  ambiguity responses; changing only a registration label preserves access.
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

- Final-review fix wave (2026-10-20), each with tests: typing every 100 ms
  never arms the prompt and 300 ms of quiet does; a client closing its socket
  while its prompt is up withdraws the prompt over a real socket; queued
  same-app/project prompts are allowed after A; a secret-free line and a
  `[y/N]` prompt are emitted at once with a 680-byte secret configured, and
  every two-chunk split of text around a secret masks like the whole text;
  merge of same names with different ids; duplicate names refused by the
  broker; 48-character truncation collision in migration; the one-time `.v1`
  copy; a symlinked Cursor config; foreign `case` entries in all three
  clients; options after the command; Touch ID text; a logging guard over
  the Case, WhytapCaseKit and WhytapCLI sources. Offscreen render of the
  prompt under a 240 pt agent card.

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
- Deferred minors: the socket path can exceed 104 bytes for a very long home;
  Russian labels vs English errors (ask Maxim); rewrites of
  `${HOME}/.claude/settings.json` and `${HOME}/.cursor/mcp.json` re-sort keys (content kept,
  `.bak` saved); built-in OpenCode PIDs depend on process plumbing.

2026-10-19. Commits: 0fee034..225df91 on branch claude/sad-nobel-2aaef9, final
packaging and docs commit follows. Fix wave 2026-10-20: 084e293..4511f84 and
the docs commit after it.

## 2026-10-20: held drawer and Doppler import

The 145 pt menu viewport is too short for managing keys. Case now uses a
320 pt content viewport while preserving the compact island width and shared
hit-band geometry. The access action explicitly describes access to keys;
its screen explains that connected clients use keys in commands.

Touch ID can end SwiftUI hover tracking while the person moves their hand to
the sensor. A system-interaction hold keeps the current panel in place across
success or cancellation. Returning directly into that visible drawer counts
as staying in an expanded panel; outside click, Escape or switching tools
releases an inactive hold. The existing activity/preemption policy still wins.

Doppler import uses the existing CLI login and reads all pages of projects
and configurations before one encrypted vault save. Each configuration maps
to a stable project ID and a distinct project/config group because Case has
no environment selector yet. Unchanged reimports are idempotent; differing
local values abort the merge. No plaintext export/fallback file is created,
and values never enter UI state, provider configurations, diagnostics or
process arguments. Generated DOPPLER_PROJECT/ENVIRONMENT/CONFIG metadata is
excluded. Empty and multiline values are preserved. Read, validation,
cancellation and conflict failures do not commit partial imports.

Physical Touch ID, keyboard restoration and real import are acceptance on the
installed shared app. Synthetic tests and offscreen native renders do not
establish those live results. UI choices are recorded in [DESIGN.md](../DESIGN.md).
