---
id: exodia-shared-app-development
type: process
title: Parallel feature sessions and one shared working application
summary: Isolate feature work, serialize checked main integration and update one identifiable installed Exodia without interrupting the user.
status: confirmed
tags: [development, agents, worktrees, integration, main, build, rollback]
canonical_for: [parallel-development, shared-working-application]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: On 2026-10-19 the user approved regular integration of checked features and requested persistent instructions for parallel sessions, one working application, an explicit build checklist and coordination of overlapping features.
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/dev-run.sh
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/customize.py
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/BuildConfig.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Updates/UpdateController.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/History/HistoryStore.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsStore.swift
    confirmed_at: 2026-10-19
related: [../project.md, local-customization.md, ../decisions/2026-10-19-shared-working-app.md]
---

# Parallel development, one working Exodia

This is the required workflow for the maintainer's parallel coding sessions.
It is an agent procedure; it does not install a background integration service.

## Shared application and source

The user's working application is `/Applications/Exodia.app`, production bundle
identity `com.rootwise.sidekey`. Keep its existing signing identity, Keychain
services and data locations. A switch to Beta changes some credentials, local
stores and permissions; do not use it as a shortcut for sharing development.
Only this installed application is used for ordinary user acceptance.

`origin/main` is the shared source of ready features. Each feature has its own
branch and worktree, normally based on current `origin/main`. Keep the primary
checkout free for integration once its existing work is reconciled. Until then,
use a clean integration worktree; never reset, stash or commit another session's
changes to make room. The human-readable local status always lives at
build/CURRENT_BUILD.md in the **primary checkout**, regardless of which
worktree builds the candidate. `build/` is Git-ignored.

## Feature session

**Exactly one live Exodia instance, across all channels.** Beta is not a
data sandbox: meetings, staged audio and clipboard history share stores with
production, and two processes also compete for the same global hotkeys/event
taps. Keep the user's working instance; do not launch a second app for testing.

1. Read the current shared guidance and this procedure before starting. Before
   integration or any app build/install action, fetch `origin` and also read
   the command shown below; an old worktree's instructions may be stale.

   ```bash
   git show origin/main:AGENTS.md
   ```

2. Inspect open PRs and relevant active branches for shared files, runtime paths
   and duplicate implementations. State dependencies and user-visible changes
   in the PR. Disjoint files can still change the same behavior.
3. Edit only the task's worktree. Build and test there with `swift build`,
   `swift test --filter ...` and other relevant non-launching checks. Keep each
   worktree's build output separate. Tests use temporary stores and fake
   providers rather than the user's notes, clipboard, keys or paid requests.
4. Do **not** invoke `scripts/dev-run.sh`, `customize.py build/run`, `swift run`,
   `open` on a feature bundle, or LaunchServices registration. On branches
   older than the one-running-copy change (2026-10-19), even `dev-run.sh`
   without `--run` stops other beta processes. Do not
   install a feature branch over `/Applications/Exodia.app` or stop its process.
   Production app/DMG packaging (`FLAVOR=prod` builds) is also reserved for
   the integrator under the shared lock; a worker's ordinary `swift build`
   does not package or register an app.
5. Submit a focused PR with the exact commit, checks and their limitations,
   dependencies/overlaps, and 1–3 concrete user acceptance steps. A feature is
   ready only after relevant review, build and behavior checks; unfinished work
   stays on its branch. Say **ready, not yet in the working app** until promoted.

Normal technical conflicts are resolved from current code and accepted
requirements. Reuse one implementation for duplicate work; preserve both
features' contracts. Report an overlap with the affected feature/PR names,
the actual conflict, the proposed resolution and whether it blocks integration.
Ask the user only if a product choice, destructive migration, access or
otherwise unresolved risk needs their decision. Cross-chat messages still
require the user's authorization; PR readiness and local status do not depend
on an unavailable messaging tool.

## Integrator: one writer at a time

Any session may act as integrator for its ready task. Routine integration and
local refresh are authorized by this workflow; do not ask again for each
checked feature. This does not authorize unrelated changes or public releases.

Acquire the repository-wide lock before merging shared main, changing the
installation or writing shared status. All worktrees resolve the same Git common directory:

```bash
integration_git_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
mkdir "${integration_git_dir}/exodia-integration.lock"
```

Creation must succeed before proceeding. Record owner session, host, process
PID and acquisition time inside the directory. Keep acquisition, protected
operations and cleanup in one live process; an exited shell's PID is not a
valid lease. A busy lock means queue the ready task and report its state; do
not start a second integration or remove a lock because of its age. Recover a
stale lock only after verifying its owner is gone and no protected operation
is still running. Release only your own lock when finished or deferring.
The directory lock is a cooperative agent rule, not an existing script guard.

Under the lock:

1. Fetch current main. In the task's clean integration candidate, incorporate
   the latest base without discarding others' changes. Review both
   `git diff origin/main...HEAD` and the resulting combined tree. An ancestor
   check or a conflict-free merge alone does not prove existing features survive.
2. Resolve dependencies and gather review findings before final validation.
   Check the affected behavior and adjacent interactions. For runtime changes,
   run the required local build/tests, including the integrated full suite, on
   the final candidate. Documentation-only changes use documentation checks.
   Keep GitHub Actions disabled. Do not repeat broad checks without a change,
   failure or concrete remaining risk.
3. Merge through the repository's PR workflow, checking the exact reviewed head
   SHA and base. If either moves, reconcile and validate the affected result.
   Fetch and verify the merged source/tree before packaging. Do not force-push
   shared main or bypass existing review/release gates.
4. For a runtime update, prepare a signed production candidate from clean,
   committed main using the current local build-only packaging procedure in
   `docs/build-and-release.md`. Building must leave the installed app running.
   Verify the candidate's strict code signature and compare its signing
   identity/designated requirement with the installed app before replacement.
   A mismatch means pending until reconciled, not a silent ad-hoc fallback or
   identity migration. Respect release provenance. For a new local promotion,
   `CFBundleVersion` must be higher than the installed build and must follow
   feed ordering; do not decrease the app's display version. Record any initial
   version mismatch between the installed app and main before preparing it.
   Inspect scripts before running them: their behavior may differ across
   branches. Do not run a publish/upload command for a local refresh.
5. Preserve the last known working signed bundle privately before replacement.
   A data migration also needs a consistent private backup using the store's
   backup mechanism or a quiescent copy; copying an open SQLite file is not a
   reliable backup. Never inspect user content as part of a build check.
   Recheck app activity immediately before promotion. A meeting recording,
   dictation, agent operation, unfinished save/processing, or unknown activity
   means **pending**. Do not infer idle from the process existing or low CPU.
   Current Sparkle guards do not protect an external script. If there is no
   reliable activity signal, wait for a known safe handoff; never force-quit.
6. Only at that safe handoff, quit normally, verify exit, replace the canonical
   installed bundle without exposing a partial copy, then launch that exact
   path. Keep one runtime instance and verify its identity and a focused smoke
   scenario. Do not reset TCC, delete stores, overwrite a live database backup
   or change bundle/channel identity to make a check pass.

## Build receipt and acceptance

Update the local build/CURRENT_BUILD.md under the lock. Keep these separate:

| State | Required evidence |
| --- | --- |
| Ready | PR/head SHA, checks, dependencies and acceptance steps |
| Merged | Verified main SHA; no claim that the app changed |
| Candidate / pending | Source SHA, signed artifact path, reason it is waiting |
| Running | Verified launched process, bundle/channel, version/build, source SHA and smoke result |

The receipt includes the last verified running build, previously working bundle,
newly included features/PRs, 1–3 immediate acceptance steps and pending features.
Build scripts must preserve this receipt; if a packaging step cleans its parent
directory, retain it privately and restore it under the same lock.
Record timestamps with an explicit timezone. Keep content, credentials and
private project paths out of public PRs; the local receipt contains build
metadata only. Never put a pending feature in the running build's checklist.

Use the application's in-process build identity when available. Check the exact
running executable path and source metadata (`ExodiaSourceRevision` where
supported), not the caller's branch or the generic dev version `9999`. Metadata
read from disk cannot identify an older process if its bundle was replaced
after launch. In that case mark the running revision unknown until verified.

After promotion tell the user: **which build is running; which features were
added; what to check; what is still pending**. A successful build, `open` call
or merge is insufficient evidence of an installed, functioning application.

## Recovery and first adoption

On a regression, retain the known working app or restore its preserved bundle
at the same canonical path at a safe handoff. Revert the offending source change
through a new reviewed commit/PR (use the correct revert form for the actual
merge strategy); never rewrite shared main. A binary rollback does not reverse
data migrations. Check compatibility before launching an older binary and keep
the current app/data if compatibility is unknown.

Before the first main-based refresh, inventory the actual installed build and
reconcile its source with main. In particular, an already installed build from
a feature branch may contain fixes not in main yet. Integrate/review those
fixes before replacing it; do not silently downgrade to an older source tree.
Preserve the primary checkout's WIP for its owning session to reconcile.

Publish this procedure through main and synchronized `AGENTS.md`/`CLAUDE.md`.
Existing sessions must reread it before their next integration/build action;
do not overwrite all active worktrees or claim that old chats reread files
automatically. Keep their feature changes intact while they incorporate main.
