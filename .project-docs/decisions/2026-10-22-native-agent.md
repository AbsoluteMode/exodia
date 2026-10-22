---
id: native-agent-2026-10-22
type: decision
title: Native Whytap agent with Tavily search and a dedicated workspace
summary: Replace OpenCode dispatch with a bounded direct model/tool loop, preserve selected routes and memory, and configure Tavily independently.
status: confirmed
tags: [agent, native, tavily, search, workspace, context, actions, privacy]
canonical_for: [agent-runtime, agent-web-search, agent-workspace]
verified_at: 2026-10-22
sources:
  - type: user-confirmed
    reference: On 2026-10-22 the user authorized a lightweight custom agent instead of OpenCode, Tavily search, fast initialization and a dedicated workspace; approve and bypass modes are a later phase. They selected the Whytap data folder separately from source code.
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentProvider.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentModel.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentTools.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/TavilySearch.swift
    confirmed_at: 2026-10-22
related: [../project.md, 2026-10-22-agent-answers-and-screen.md]
---

# Decision

Run Whytap Agent inside the app, reusing the controller, voice flow, island,
provider routing and Keychain. OpenCode is no longer started for built-in
requests. Keep its source and old local data for compatibility and recovery;
do not delete history or credentials. Migrate an explicitly connected OpenCode
agent to the native runtime while preserving the exact model/provider/endpoint
and action setting. A disconnected agent stays disconnected.
Keep the legacy opencode connection identifier on disk while resolving native
dispatch in memory, so restoring the retained app does not lose its connection.

Initialization reads bounded local AGENTS.md memory and recent text pairs, then
sends the selected provider one request with the entire small tool catalog.
No version probe, subprocess daemon, MCP discovery, login shell, model listing
or separate model handshake precedes it. This removes harness startup work;
it does not promise a fixed model/provider latency or eliminate model mistakes.
Connect verifies local prerequisites without a paid request; API-key acceptance
is established by the provider when a model request runs.

Use OpenRouter Chat Completions, OpenAI Responses (store:false, replay encrypted
reasoning), and Anthropic Messages. Retain native assistant/tool/reasoning items
inside each loop so call IDs, encrypted reasoning and thinking signatures remain
valid. Never switch providers/models automatically. Report provider errors
without echoing response bodies. Existing cost recording receives reported
OpenRouter charges; unreported costs remain unavailable, not zero.

The dedicated workspace is `Application Support/whytap/agent`, outside source.
AGENTS.md remains durable memory. The new native-conversation.json retains only
completed user/assistant text pairs, at most six pairs and 12,000 characters.
Reuse requires the same route/endpoint and session ID within 15 minutes. Expired
context is ignored; the file is replaced on a later successful turn, not deleted
by a timer. Tool results, reasoning and screenshot pixels remain in flight and
are excluded from this new file. Old OpenCode data remains unused on disk.
One app-owned system prompt directs compact answer-first replies, requested
screenshots and typed show_actions buttons; the legacy JSON extractor is a
compatibility fallback. It is a bounded conversation, not an empty context for
every question. Memory, file/selection/web/tool content and pixels are evidence,
not authorization or higher-priority instructions.

Tavily has a separate Settings → Agents → Web search key in Keychain. Save uses
GET /usage rather than a search. A failed replacement preserves the old key.
POST /search uses basic search, five results, no generated answer/raw pages or
images, and sends the tool query only. Cap two searches per turn and bound all
returned excerpts. Missing configuration produces a setup error; no alternative
search service is chosen. The key joins the existing encrypted credential backup
allowlist. Tavily credit cost is not added to model inference totals.

The local tool catalog covers list/read/search, HTTPS fetch, requested screenshot,
Case key names, answer actions, write and shell. Capture calls the app-owned
ScreenCaptureKit service directly; the existing MCP scopes remain compatible.
Case uses the signed helper and existing broker approvals. Register only the
native shell child PID, released at exit; never register the app PID or read
vault files directly. A gated shell startup makes that identity available before
a Case request can be sent. Commands have an isolated process group, 30-second
deadline and bounded output. Cancellation signals the group, then bounds the
output drain even if a child detached into another session. An inherited open
pipe produces an incomplete/stopped warning, never a clean Exit 0. Detached
processes may survive; persistent background jobs require a separate facility.
Do not pass model keys or unrelated app descriptors to child processes.

Preserve agent.opencode.allowActions: on permits file writes/commands under the
Mac user's permissions; off omits and rejects them. The UI names that concrete
behavior. Approval prompts and bypass modes are explicitly a later phase.
The overall loop has a three-minute deadline, 12 model steps, 48 tool calls,
context limits, cancellation and no automatic retries of paid calls or side
effects. This is not a filesystem sandbox.

# Validation

Use synthetic provider responses, temporary files/preferences and in-memory
keys. Verify first-request tools/exact route, each provider's tool round trip,
image format and reasoning retention, action metadata, disabled writes/commands,
Tavily auth/query/result bounds and failed replacement, HTTP body redaction,
conversation expiry/scope and shell timeout/cancellation.
Include a detached-child/open-pipe regression, signal exit status, descriptor
inheritance and rollback-compatible connection settings. Render native Settings
offscreen in both appearances without launching another app or reading keys.
Live Tavily credentials, real provider/model behavior and Screen Recording remain
separate acceptance checks in the one installed app.
