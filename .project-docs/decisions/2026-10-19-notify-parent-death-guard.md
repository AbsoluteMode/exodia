---
id: notify-parent-death-guard-2026-10-19
type: decision
title: End Notify script process groups when the app is killed or crashes
summary: Each Notify source runs under a perl stdin-EOF guard that leads its process group; when the app dies the kernel closes the guard's stdin and the guard terminates the whole group.
status: confirmed
tags: [notifications, lifecycle, processes]
canonical_for: [notify-script-lifecycle-on-app-death]
verified_at: 2026-10-19
sources:
  - type: repository
    reference: Sources/Sidekey/Notifications/NotifyProcess.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Tests/SidekeyTests/Notifications/NotifyProcessTests.swift
    confirmed_at: 2026-10-19
related: [2026-10-19-nowplaying-adapter-shutdown.md, 2026-10-19-script-notifications.md]
---

# Notify scripts die with the app

## Context

`NotifyScriptSupervisor` starts each source as its own process group
(`NotifyProcess`, `posix_spawn` with `POSIX_SPAWN_SETPGROUP`) and stops the
group on disable, removal, sleep and quit. On 2026-10-19 a `kill -9` of the
app left `telegram-all-incoming/worker.py` running with PPID 1. The relaunched
app could not start its own copy: the worker takes
`fcntl.flock(worker.lock, LOCK_EX | LOCK_NB)` and exits when the lock is held,
so the orphan blocked the source until it was killed by hand. SIGKILL and
crashes skip every app-side cleanup path.

## Decision

The same stdin-EOF guard as Now Playing, adapted to process groups.
`NotifyProcess` spawns `/usr/bin/perl -e <parentWatchGuardScript> --
<command…>` as the group leader, with stdin the read end of a pipe whose
write end (`FD_CLOEXEC`) only the app holds. The guard forks the script
(stdin on /dev/null, same group, argv exec'd literally) and blocks reading
its stdin.

- App dies (SIGKILL, crash, normal exit): the kernel closes the write end,
  the guard reads EOF, ignores TERM itself, sends TERM to the whole group,
  waits up to 1 s for the script, then KILLs the group (itself included).
  The 1 s grace mirrors `stop()` and lets a worker save state on TERM.
- Script exits on its own: the guard exits with the script's code
  (128+signal when signalled), so retry/backoff behave as before.
- `stop()`: unchanged; TERM/KILL to the group reaches guard and script.

The spawn now sets an empty signal mask (`POSIX_SPAWN_SETSIGMASK`). Spawning
threads (GCD, Swift concurrency) can have SIGCHLD blocked, and the mask is
inherited: tests showed the guard then never noticed the script exiting and
hung. Scripts also get an unblocked mask now, which they should have had.

Because the guard always starts, `NotifyProcess` checks that the script path
is an executable regular file first, so a missing executable still fails at
start ("Couldn’t start") instead of becoming a retried exit 127.

## Why

- stdin EOF is immediate and free: no polling of `getppid()`, no timers.
- One guard per group covers the script's helpers too, which a per-process
  watch could not; leading the group lets the guard address it by its own
  PGID, and the existing zombie-leader reservation keeps protecting the PGID
  from reuse until cleanup ends.
- No change to user scripts and no new contract for them beyond "stdin is
  /dev/null", which was already true.

## What was tested

- `NotifyProcessTests.testLifelineEOFStopsScriptAndHelpers`: closing the
  app's end (`closeLifeline()`, what the kernel does on death) ends the
  script and a TERM-ignoring helper; both run in the guard's group under it.
- `testGuardReportsScriptExitStatusAndGivesScriptNullStdin`: exit 3 arrives
  as raw status 3<<8, an instant `/usr/bin/true` reports 0 (fork/SIGCHLD
  race), `cat` sees EOF immediately.
- `NotifyScriptSupervisorTests.testFailingScriptRestartsWithBackoff`: a
  failing source is relaunched after the 2 s first backoff.
- Existing tests: group stop with TERM-ignoring helpers, output drain before
  exit, literal argv, missing executable, enable/disable/remove.
- By hand: a perl parent spawned the guard exactly like `NotifyProcess`
  (own group, stdin pipe) around `sh` with a TERM-ignoring `sleep 60`; after
  `kill -9` of the parent, guard, script and helper were gone within 1.5 s.
- Not checked: the installed app under `kill -9` (feature sessions do not
  install builds); the existing orphan was left alone.

## Rejected

- Polling `getppid()` in a wrapper: wakeups and delay for no gain.
- Asking scripts to watch for EOF themselves: every source would need it,
  and helpers would still leak.
- A LaunchAgent or `kqueue` `NOTE_EXIT` watcher process: a second service to
  manage for what one pipe does.
- Reaping orphans on the next launch by lock or PID file: kills a process
  after the fact and needs per-script knowledge of what to look for.

2026-10-19, branch claude/brave-hamilton-579e4b
