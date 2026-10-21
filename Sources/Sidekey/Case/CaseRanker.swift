import Foundation

struct CaseListEntry: Equatable, Identifiable {
    enum Kind: Equatable {
        case secret
        case project
    }

    let id: UUID
    let kind: Kind
    let displayName: String
    let description: String
    /// For a secret, its project; for a project, its own ID.
    let projectID: UUID
    let score: Double
    /// How the entry matches the query; `.none` without a query.
    var match: CaseMatch = .none
}

/// Match strength: a stronger bucket first, then more query parts found,
/// then fewer of them found only through a typo. Usage
/// (`CaseListEntry.score`) only decides between equal matches.
struct CaseMatch: Equatable {
    enum Bucket: Int, Comparable {
        case exact
        case prefix
        case contains
        /// The project's name covers part of the query and the key's name
        /// the rest (`whytap github`). A key matching the whole query by
        /// name stays ahead.
        case projectQualified
        /// Only the query's first part starts the name; later parts that
        /// start a word of the name add to `matchedParts`, and so does a
        /// later part of three or more characters one typo away from a word
        /// start (counted in `typos`).
        case firstTokenPrefix
        case description
        case none

        static func < (lhs: Bucket, rhs: Bucket) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let bucket: Bucket
    let matchedParts: Int
    var typos = 0

    static let none = CaseMatch(bucket: .none, matchedParts: 0)

    var isPartial: Bool { bucket == .firstTokenPrefix }

    func isStronger(than other: CaseMatch) -> Bool {
        if bucket != other.bucket { return bucket < other.bucket }
        if matchedParts != other.matchedParts { return matchedParts > other.matchedParts }
        return typos < other.typos
    }
}

enum CaseRanker {
    private static let freshnessHalfLifeDays = 30.0
    private static let newKeyBoostWindowSeconds = 86_400.0
    private static let newKeyBoost = 0.15
    private static let minimumProjectPartLength = 2
    private static let minimumTypoPartLength = 3

    static func sortedEntries(
        secrets: [CaseSecret],
        projects: [CaseProject],
        query: String,
        now: Date = Date()
    ) -> [CaseListEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = try? CaseNameNormalizer.normalizedName(trimmedQuery)
        let searchText = normalizedQuery ?? trimmedQuery.uppercased()
        let queryParts = words(of: searchText)

        // Every key is an entry of its own; General joins project entries
        // while searching, so a query finds keys (any project) by name and
        // description and projects by name and description. The island draws
        // projects itself and reads these entries only while searching.
        let groupProjects = projects.filter { $0.id != CaseProject.generalID || !trimmedQuery.isEmpty }
        let individualEntries = secrets
            .map { secret in
                CaseListEntry(
                    id: secret.id,
                    kind: .secret,
                    displayName: secret.name,
                    description: secret.description,
                    projectID: secret.projectID,
                    score: score(copyCount: secret.copyCount, lastCopiedAt: secret.lastCopiedAt, createdAt: secret.createdAt, now: now)
                )
            }

        var childScores: [UUID: Double] = [:]
        for entry in individualEntries {
            childScores[entry.projectID] = max(childScores[entry.projectID] ?? 0, entry.score)
        }
        let groupEntries = groupProjects.map { project in
            let childScore = childScores[project.id] ?? 0
            let ownScore = score(copyCount: 0, lastCopiedAt: nil, createdAt: project.createdAt, now: now)
            return CaseListEntry(
                id: project.id,
                kind: .project,
                displayName: project.name,
                description: project.description,
                projectID: project.id,
                score: max(ownScore, childScore)
            )
        }

        // Query parts that start a word of a project's name (`whytap github`)
        // leave the rest of the query for that project's keys.
        // WHY: docs/decisions/2026-10-21-case-search-project-ranking.md
        let projectQualifiers = searchText.isEmpty ? [:] : Dictionary(
            projects.compactMap { project in qualifier(projectName: project.name, queryParts: queryParts).map { (project.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )

        let entries = groupEntries + individualEntries
        let matched = entries.compactMap { entry -> CaseListEntry? in
            guard !searchText.isEmpty else { return entry }
            var best = Self.match(entry: entry, query: searchText, queryParts: queryParts, rawQuery: trimmedQuery)
            if entry.kind == .secret, let qualifier = projectQualifiers[entry.projectID] {
                let rest = Self.match(name: entry.displayName, query: qualifier.remaining.joined(separator: "_"),
                                      queryParts: qualifier.remaining)
                let qualified = CaseMatch(bucket: rest.isPartial ? .firstTokenPrefix : .projectQualified,
                                          matchedParts: qualifier.covered + rest.matchedParts, typos: rest.typos)
                if rest.bucket != .none, qualified.isStronger(than: best) { best = qualified }
            }
            guard best.bucket != .none else { return nil }
            var matchedEntry = entry
            matchedEntry.match = best
            return matchedEntry
        }

        return matched.sorted { lhs, rhs in
            if lhs.match != rhs.match {
                return lhs.match.isStronger(than: rhs.match)
            }
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return lhs.displayName < rhs.displayName
        }
    }

    /// Project IDs ordered by each project's best entry in `entries` (as
    /// sorted by `sortedEntries`): its own name/description match or its best
    /// key. Equal projects keep `defaultOrder`; projects without entries are
    /// left out.
    static func projectOrder(_ entries: [CaseListEntry], defaultOrder: [UUID]) -> [UUID] {
        var best: [UUID: CaseListEntry] = [:]
        for entry in entries where best[entry.projectID] == nil {
            best[entry.projectID] = entry
        }
        let ranked = defaultOrder.enumerated().compactMap { index, id in
            best[id].map { (index: index, id: id, entry: $0) }
        }
        return ranked.sorted { lhs, rhs in
            if lhs.entry.match != rhs.entry.match {
                return lhs.entry.match.isStronger(than: rhs.entry.match)
            }
            if lhs.entry.score != rhs.entry.score {
                return lhs.entry.score > rhs.entry.score
            }
            return lhs.index < rhs.index
        }.map(\.id)
    }

    static func score(copyCount: Int, lastCopiedAt: Date?, createdAt: Date, now: Date = Date()) -> Double {
        let usageScore = log(Double(copyCount) + 1)
        let freshness: Double
        if let lastCopiedAt {
            let days = max(0, now.timeIntervalSince(lastCopiedAt) / 86_400)
            freshness = exp(-days / freshnessHalfLifeDays)
        } else {
            freshness = 0
        }
        let age = now.timeIntervalSince(createdAt)
        let boost = age >= 0 && age < newKeyBoostWindowSeconds ? newKeyBoost : 0
        return usageScore * freshness + boost
    }

    private static func match(entry: CaseListEntry, query: String, queryParts: [String], rawQuery: String) -> CaseMatch {
        let byName = match(name: entry.displayName, query: query, queryParts: queryParts)
        if byName.bucket != .none { return byName }
        if !rawQuery.isEmpty,
           entry.description.range(of: rawQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return CaseMatch(bucket: .description, matchedParts: queryParts.count)
        }
        return .none
    }

    private static func match(name: String, query: String, queryParts: [String]) -> CaseMatch {
        let haystack = name.uppercased()
        let needle = query.uppercased()
        if needle.isEmpty { return .none }
        let all = queryParts.count
        if haystack == needle { return CaseMatch(bucket: .exact, matchedParts: all) }
        if haystack.hasPrefix(needle) { return CaseMatch(bucket: .prefix, matchedParts: all) }
        if haystack.contains(needle) { return CaseMatch(bucket: .contains, matchedParts: all) }

        guard let firstPart = queryParts.first else { return .none }
        if queryParts.allSatisfy({ haystack.contains($0) }) {
            return CaseMatch(bucket: .contains, matchedParts: all)
        }
        if haystack.hasPrefix(firstPart) {
            // `github_lan_key` finds more of GITHUB_LENDING_KEY than of GITHUB_TOKEN:
            // `key` starts a word, and `lan` is one typo from `len`.
            let nameWords = words(of: haystack)
            var found = 1
            var typos = 0
            for part in queryParts.dropFirst() {
                if nameWords.contains(where: { $0.hasPrefix(part) }) {
                    found += 1
                } else if part.count >= minimumTypoPartLength,
                          nameWords.contains(where: { startsWithinOneTypo($0, part: part) }) {
                    found += 1
                    typos += 1
                }
            }
            return CaseMatch(bucket: .firstTokenPrefix, matchedParts: found, typos: typos)
        }
        return .none
    }

    /// Whether `part` is one substitution, insertion, deletion or swap of
    /// neighbours away from the start of `word`. The start compared has at
    /// least three letters, so `lan` never matches a word starting with AN.
    private static func startsWithinOneTypo(_ word: String, part: String) -> Bool {
        let part = Array(part)
        let word = Array(word)
        return [part.count, part.count - 1, part.count + 1].contains { length in
            length >= minimumTypoPartLength && length <= word.count && isWithinOneEdit(part, Array(word[..<length]))
        }
    }

    private static func isWithinOneEdit(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        if lhs.count == rhs.count {
            let differences = lhs.indices.filter { lhs[$0] != rhs[$0] }
            if differences.count <= 1 { return true }
            guard differences.count == 2, let first = differences.first, differences[1] == first + 1 else { return false }
            return lhs[first] == rhs[first + 1] && lhs[first + 1] == rhs[first]
        }
        let (longer, shorter) = lhs.count > rhs.count ? (lhs, rhs) : (rhs, lhs)
        guard longer.count == shorter.count + 1 else { return false }
        var index = 0
        while index < shorter.count, longer[index] == shorter[index] {
            index += 1
        }
        return longer[(index + 1)...].elementsEqual(shorter[index...])
    }

    /// The query parts a project's name covers (each, at least two
    /// characters, starts a word of the name) and the rest, or nil unless
    /// both are non-empty. A single typed letter names no project.
    private static func qualifier(projectName: String, queryParts: [String]) -> (covered: Int, remaining: [String])? {
        let nameWords = words(of: projectName.uppercased())
        let remaining = queryParts.filter { part in
            part.count < minimumProjectPartLength || !nameWords.contains { $0.hasPrefix(part) }
        }
        guard !remaining.isEmpty, remaining.count < queryParts.count else { return nil }
        return (queryParts.count - remaining.count, remaining)
    }

    private static func words(of text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
