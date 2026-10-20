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
}

enum CaseRanker {
    private static let freshnessHalfLifeDays = 30.0
    private static let newKeyBoostWindowSeconds = 86_400.0
    private static let newKeyBoost = 0.15

    static func sortedEntries(
        secrets: [CaseSecret],
        projects: [CaseProject],
        query: String,
        now: Date = Date()
    ) -> [CaseListEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = try? CaseNameNormalizer.normalizedName(trimmedQuery)
        let searchText = normalizedQuery ?? trimmedQuery.uppercased()

        // Every key is an entry of its own, and every project except General
        // is one too, so a query finds keys (any project) by name and
        // description and projects by name and description. The island draws
        // projects itself and reads these entries only while searching.
        let groupProjects = projects.filter { $0.id != CaseProject.generalID }
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

        let groupEntries = groupProjects.map { project in
            let childScore = secrets
                .filter { $0.projectID == project.id }
                .map { score(copyCount: $0.copyCount, lastCopiedAt: $0.lastCopiedAt, createdAt: $0.createdAt, now: now) }
                .max() ?? 0
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

        let entries = groupEntries + individualEntries
        let filtered = searchText.isEmpty ? entries : entries.filter {
            matchBucket(entry: $0, query: searchText, rawQuery: trimmedQuery) != .none
        }

        return filtered.sorted { lhs, rhs in
            let lhsBucket = searchText.isEmpty ? MatchBucket.none : matchBucket(entry: lhs, query: searchText, rawQuery: trimmedQuery)
            let rhsBucket = searchText.isEmpty ? MatchBucket.none : matchBucket(entry: rhs, query: searchText, rawQuery: trimmedQuery)
            if lhsBucket.sortOrder != rhsBucket.sortOrder {
                return lhsBucket.sortOrder < rhsBucket.sortOrder
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

    private enum MatchBucket {
        case exact
        case prefix
        case contains
        case firstTokenPrefix
        case description
        case none

        var sortOrder: Int {
            switch self {
            case .exact: return 0
            case .prefix: return 1
            case .contains: return 2
            case .firstTokenPrefix: return 3
            case .description: return 4
            case .none: return 5
            }
        }
    }

    private static func matchBucket(entry: CaseListEntry, query: String, rawQuery: String) -> MatchBucket {
        let byName = matchBucket(name: entry.displayName, query: query)
        if byName != .none { return byName }
        if !rawQuery.isEmpty,
           entry.description.range(of: rawQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return .description
        }
        return .none
    }

    private static func matchBucket(name: String, query: String) -> MatchBucket {
        let haystack = name.uppercased()
        let needle = query.uppercased()
        if needle.isEmpty { return .none }
        if haystack == needle { return .exact }
        if haystack.hasPrefix(needle) { return .prefix }
        if haystack.contains(needle) { return .contains }

        let queryParts = needle.split(separator: "_").map(String.init)
        if queryParts.allSatisfy({ haystack.contains($0) }) {
            return .contains
        }
        if let firstPart = queryParts.first, haystack.hasPrefix(firstPart) {
            return .firstTokenPrefix
        }
        return .none
    }
}
