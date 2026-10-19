import Foundation

struct CaseListEntry: Equatable, Identifiable {
    enum Kind: Equatable {
        case secret
        case group
    }

    let id: UUID
    let kind: Kind
    let displayName: String
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

        // Interim list model until the project UI lands: General's keys are
        // listed individually, every other project is a collapsible row.
        let groupProjects = projects.filter { $0.id != CaseProject.generalID }
        let individualEntries = secrets
            .filter { secret in
                secret.projectID == CaseProject.generalID
                    || !groupProjects.contains { $0.id == secret.projectID }
            }
            .map { secret in
                CaseListEntry(
                    id: secret.id,
                    kind: .secret,
                    displayName: secret.name,
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
                kind: .group,
                displayName: project.name,
                score: max(ownScore, childScore)
            )
        }

        let entries = groupEntries + individualEntries
        let filtered = searchText.isEmpty ? entries : entries.filter {
            matchBucket(name: $0.displayName, query: searchText) != .none
        }

        return filtered.sorted { lhs, rhs in
            let lhsBucket = searchText.isEmpty ? MatchBucket.none : matchBucket(name: lhs.displayName, query: searchText)
            let rhsBucket = searchText.isEmpty ? MatchBucket.none : matchBucket(name: rhs.displayName, query: searchText)
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
        case none

        var sortOrder: Int {
            switch self {
            case .exact: return 0
            case .prefix: return 1
            case .contains: return 2
            case .firstTokenPrefix: return 3
            case .none: return 4
            }
        }
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
