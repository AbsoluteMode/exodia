---
id: nowplaying-adapter-shutdown-2026-10-19
type: decision
title: Terminate the MediaRemote stream child synchronously on quit
summary: applicationWillTerminate stops Now Playing through a synchronous shutdown, and a perl stdin-EOF guard around the untouched vendored run.pl ends the stream when the app is killed or crashes.
status: confirmed
tags: [nowplaying, lifecycle, processes]
canonical_for: [nowplaying-adapter-lifecycle]
verified_at: 2026-10-19
sources:
  - type: repository
    reference: Sources/Sidekey/NowPlaying/MediaRemoteNowPlayingSource.swift
    confirmed_at: 2026-10-19
  - type: user-confirmed
    reference: On 2026-10-19 the user approved a stdin-EOF guard and required the vendored run.pl to remain untouched.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/AppDelegate.swift
    confirmed_at: 2026-10-19
related: [2026-10-19-notify-parent-death-guard.md, 2026-10-19-one-running-copy.md]
---

# MediaRemote adapter shutdown

## Context

Now Playing reads a long-lived child `/usr/bin/perl run.pl <framework> stream
--no-diff --micros`. On 2026-10-19 the machine had 23 such processes, 22 with
PPID 1, some three days old, from the installed app, the removed Whytap app
and dev builds. After an ordinary quit of installed 2.2.11 its adapter stayed
alive as an orphan.

Causes:

1. `applicationWillTerminate` stopped many components but not Now Playing.
2. `NowPlayingController.stop()` never reached the source at all.
3. `MediaRemoteNowPlayingSource.stop()` hops onto its serial queue with
   `async`; `applicationWillTerminate` returns straight into `exit()`, so
   even a call to it would not run before the process ended.

## Decision

`NowPlayingSource.shutdown()` (no-op by default) is synchronous. The
MediaRemote source clears `started`, removes the termination/readability
handlers and sends SIGTERM to the stream inside `queue.sync`, so the child
is signalled before the call returns and no relaunch is scheduled.
`NowPlayingController.shutdown()` and `NowPlayingCoordinator.shutdown()`
forward it; `applicationWillTerminate` calls the coordinator.

All app-initiated quits (Settings Quit, the second-copy path, Sparkle's
install-and-relaunch) go through `NSApp.terminate`, so they share this path.

## Why

Synchronous is required by the termination contract, and a separate
`shutdown()` keeps the existing asynchronous `stop()` for runtime toggles.
`queue.sync` from the main thread is safe: nothing on the source queue waits
for the main thread.

## Sleep

The stream is not stopped on sleep. It is idle (0 % CPU) while nothing
changes, MediaRemote keeps working across sleep, and the existing
termination handler relaunches it if macOS ever kills it.

## What was tested

- `MediaRemoteNowPlayingSourceTests`: a stand-in `run.pl` (`sleep 600`)
  runs as the real stream process; after `shutdown()` the PID is gone and no
  relaunch follows after the 0.2 s relaunch delay. The same through
  `NowPlayingCoordinator.shutdown()`.
- A spawned child of `Process` has the default SIGPIPE disposition even
  though the app ignores SIGPIPE, so an orphan would only die on a write to
  the dead pipe, which the long-lived orphans show does not reliably happen.

## Kill and crash: stdin-EOF guard

SIGKILL, a crash or an external `kill` bypass `applicationWillTerminate`.
The stream now launches as `/usr/bin/perl -e <parentWatchGuardScript> --
run.pl <framework> stream …`. The guard forks the real stream (stdin on
/dev/null, stdout inherited) and blocks reading its own stdin, whose write
end only the app holds. The kernel closes that end whenever the app dies, so
EOF makes the guard SIGTERM the stream and exit. SIGTERM to the guard
(recycle, shutdown) is forwarded; a stream that exits on its own ends the
guard, so the existing relaunch still fires. Maxim chose this on 2026-10-19
with the condition that vendored `run.pl` stays untouched.

Checked: unit tests close the app's stdin end (parent death), kill the
stream (guard exits, relaunch follows) and shut down (both PIDs gone); a
compiled Swift parent was SIGKILLed by hand and both guard and stream
exited within a second.

## Rejected

- Patching vendored `run.pl`: Maxim asked to keep it untouched, and the
  native stream loop gives perl no point to poll `getppid()`.
- Polling `getppid()` from a wrapper: periodic wakeups and up to one
  interval of delay, while stdin EOF is immediate and free.
- A separate process group: does not help with SIGKILL of the app alone.

- Calling the existing async `stop()` on quit: the block never runs before
  `exit()`.
- Stopping the stream on sleep: no measured cost while asleep, and it adds a
  restart path for no gain.

2026-10-19, branch claude/charming-gauss-2613cc
