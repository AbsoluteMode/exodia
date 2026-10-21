---
id: case-search-project-ranking
type: decision
title: Case search ranks projects by their best match
summary: Order search sections by each project's best match, let query words name a project, and credit later query parts that start key-name words, allowing one typo.
status: confirmed
tags: [case, search, ranking]
canonical_for: [case-search-ranking]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user searched `github_lan` for the whytap project's GITHUB_LENDING_KEY, saw other projects' GITHUB keys first and asked search to prioritize projects.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 the user approved tolerating one typo in the second and later query parts of three or more letters, with a test for `github_lan`.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Case/CaseRanker.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Case/CaseViewModel.swift
    confirmed_at: 2026-10-21
related: [2026-10-20-case-connect-and-scope.md, ../DESIGN.md]
---

# Case search ranks projects

## Context

The ranker already sorted matching keys and projects, but the island drew
search sections in the fixed project order (General, then by name). A project
with the best key waited for its alphabetical turn, so `whytap` came after
`acme / dev` and `sidekey / dev` for any GITHUB query. A query could not name
the project either: `whytap github` matched the project by its first word and
showed all its keys alphabetically. Every key matching only the first query
part tied in the weakest name bucket, whatever the other parts said.

## Decision

- Search sections follow each project's best entry: its own name/description
  match or its best key, by match strength and then usage. Equal projects keep
  the previous order; an empty query keeps the previous order exactly.
- Query parts of two or more characters that start a word of a project's
  name (`whytap`, `dev`, `why`) leave the rest of the query for that
  project's keys. `whytap github` and `github whytap` find whytap's GITHUB
  keys. Such a match ranks below any key whose own name contains the whole
  query, and above keys that match only the query's first part. Other
  projects' matches stay in the list.
- A project matched only by the query's first part shows only its matching
  keys (best first) when one of them matches better than the project itself;
  otherwise a matching project keeps all its keys, matching ones first.
- Among first-part-only matches, later parts that start a word of the key
  name count: `github_lan_key` puts GITHUB_LENDING_KEY above GITHUB_TOKEN.
- A later part of three or more letters also counts when it is one
  substitution, insertion, deletion or swap of neighbours away from the first
  three or more letters of a key-name word, so `github_lan` finds
  GITHUB_LENDING_KEY first while `lan` does not reach ANDROID through `an`. At
  equal parts an exact word start beats a typo. The first part stays exact, so
  typos never add keys to the results; like an exact word start, a typo match
  can still narrow a first-word project match to its matching keys.

## Why

The person looks for a key in a project they know. The section order is what
they scan, so it must follow the match rather than the alphabet. Word starts
rather than substrings keep `key` from naming `sidekey / dev`. Usage decides only
between equal matches, so a frequently copied key cannot hide a better match.
A project name only stands in for part of the query, so a key spelling out
the whole query stays ahead; one typed letter is too common a word start to
name a project.

## Tested

Synthetic ranker and view-model tests use the reported project and key names
without values: `github_len`, `github lending`, `github_lan_key`,
`whytap github`, `github whytap`, `whytap lending`, several projects with the
same key, a project-name match above a key-only match, `whytap zzz` and a
cleared query. An independent review found that a project-qualified key could
tie with or beat a key matching the whole query (`github_to` with a project
`tokens`, `openai key` with a project `Keys`); both are now tests, as is the
single-letter rule. Punctuation-only queries such as `_` now match names
containing it instead of every entry.

Typo tests cover `github_lan` (ranker and island sections), a missing, an
extra and a swapped letter, a typo pointing at another key (`github_tken`), an
exact word start beating a more used typo match, the three-letter minimum for
the part and for the word start (`lan` vs ANDROID) and an inexact first part
adding nothing. Before building it, a simulation over the user's real key
names (names only) showed `github_lan` lifting only GITHUB_LENDING_KEY among
the GITHUB keys. A second review fuzzed the edit check against brute force
(0 mismatches) and prompted the word-start minimum and the extra-letter test.

## Rejected

- Typo tolerance for the first part, which would add results while typing, or
  for one- and two-letter parts, where almost every word start is one edit away.
- Substring matching for project names: short parts such as `key` or `dev`
  would qualify unrelated projects.
- Ranking sections by their first row including key-name order: the
  alphabetical key name is not a reason to move a project.

Change: branch `claude/case-search-project-rank`.
