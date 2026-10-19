#!/usr/bin/env python3
"""Offline metadata summary; never prints meeting transcript text."""
import argparse
from bisect import bisect_left
from collections import Counter
import json
from pathlib import Path
import statistics


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def summarize(folder):
    manifest = json.loads((folder / 'manifest.json').read_text())
    activity, tokens, events = (rows(folder / name) for name in ['activity.jsonl', 'tokens.jsonl', 'events.jsonl'])
    ends = [r['end_ms'] for r in activity]
    delays = []
    for token in tokens:
        index = bisect_left(ends, token['end_ms'])
        if index < len(activity):
            frame = activity[index]
            # Account for pauses: compare wall times, not compressed audio time.
            audio_end_wall = frame['emitted_elapsed_ms'] - (frame['end_ms'] - token['end_ms'])
            delay = token['received_elapsed_ms'] - audio_end_wall
            if delay >= 0:
                delays.append(delay)
    delays.sort()
    sizes = {name: (folder / name).stat().st_size for name in ['mixed.pcm', 'mic.pcm', 'system.pcm']}
    return {'state': manifest['state'], 'audio_seconds': manifest['samples'] / manifest['sample_rate'],
            'equal_track_sizes': len(set(sizes.values())) == 1, 'audio_bytes': sizes,
            'final_tokens': len(tokens), 'token_roles': dict(Counter(t['role'] for t in tokens)),
            'speaker_count': len({t['speaker'] for t in tokens if t['speaker'] != 'unknown'}),
            'frame_emission_to_final_token_median_ms': statistics.median(delays) if delays else None,
            'frame_emission_to_final_token_p95_ms': delays[min(len(delays) - 1, int(len(delays) * .95))] if delays else None,
            'timing_warnings': sum('late_or_out_of_range' in e['event'] or 'clock_gap' in e['event'] for e in events),
            'limitations': ['Experimental signal activity mapping, not verified voice identity',
                            'Source placement uses callback arrival estimates, not hardware timestamps',
                            'Latency excludes the test mixer jitter allowance before frame emission',
                            'Decision accuracy requires independent human labels']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.bundle), indent=2))
