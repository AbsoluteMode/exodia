---
id: nowplaying-artwork-recovery-2026-10-19
type: decision
title: Recover missing Now Playing artwork with a bounded fresh read
summary: A background MediaRemote get retries missing covers without waiting for another stream event and rejects results from an earlier track or lifecycle.
status: confirmed
tags: [nowplaying, spotify, dj, artwork, recovery]
canonical_for: [nowplaying-artwork-recovery]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: On 2026-10-19 the user reported that the music-note placeholder sometimes remains after a Spotify DJ interlude.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/NowPlaying/MediaRemoteNowPlayingSource.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/NowPlaying/MediaRemoteStreamParsing.swift
    confirmed_at: 2026-10-19
  - type: url
    reference: https://github.com/ungive/mediaremote-adapter#caveats
    confirmed_at: 2026-10-19
related: [2026-10-19-nowplaying-adapter-shutdown.md]
---

# Now Playing artwork recovery

## Context

The user sees a music-note placeholder that sometimes persists after Spotify
DJ speaks. The existing source only preserves artwork from the immediately
previous event of the same track. An interlude, empty event or stream restart
breaks that chain; controller polling only rereads the cached snapshot.
There was no fresh read if artwork never arrived in another stream event.

The upstream adapter documents that artwork can load late or be absent and
recommends streaming or repeated `get` reads. A read-only probe on this machine
returned Spotify artwork, but the exact live DJ transition was not captured;
DJ as the trigger remains a hypothesis.

## Decision and rationale

When a supported track has no decoded artwork, run a separate `get --micros`
on a background queue. Permit one request at a time, with a two-second shared
deadline for process exit and stdout drain. Polling retries at most every five
seconds while artwork is absent, including after an empty/failed read. A track
change starts a new cooldown. Successful recovery stops further requests.
The existing parent-EOF guard also owns these short-lived children.

Copy only the image into the latest stream metadata. Match bundle, process,
content-item identifier, title, artist and album; also require the request's
generation to remain current. Clearing, restarting, stopping or changing
tracks invalidates a request, including A → DJ → A. Fresh artwork from the
stream wins. The same identity check protects ordinary artwork preservation.

## Alternatives

- Keeping the last cover across all tracks can show the wrong album during DJ
  speech or on a new song.
- Restarting the stream for every missing cover disrupts playback metadata.
- AppleScript artwork reads would introduce Automation consent on the normal
  MediaRemote path. Recovery uses the bundled adapter without new permissions.

## Consequences and limits

There are no credentials, new network endpoints, user-content logs or provider
requests. The framework and vendored driver stay unchanged. Truly absent
artwork retains the placeholder and bounded retries. Automated checks use
synthetic metadata, covers and stand-in processes. Live acceptance remains:
play Spotify DJ through speech into the next song and confirm that the correct
cover returns; repeat across another transition.

## Comments and objections

No additional product decision was required. The fix does not fabricate a
cover for speech that supplies none.

## Resolution

Recover the missing image independently while treating current stream metadata
as the authority for the track and playback state.

## Supersedes / superseded by

No prior decision is superseded. The adapter shutdown contract remains in force.
