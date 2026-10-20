import Foundation

enum CaseNameValidationError: Error, Equatable {
    case empty
    case rawTooLong
    case nonASCII
    case normalizedTooLong
    case leadingDigit
}

enum CaseNameNormalizer {
    static let maxRawLength = 80
    static let maxNormalizedLength = 64

    static func normalizedName(_ raw: String) throws -> String {
        guard raw.count <= maxRawLength else { throw CaseNameValidationError.rawTooLong }
        guard raw.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw CaseNameValidationError.nonASCII
        }

        var parts: [String] = []
        var current = ""

        for scalar in raw.unicodeScalars {
            let value = scalar.value
            let isDigit = value >= 48 && value <= 57
            let isUpper = value >= 65 && value <= 90
            let isLower = value >= 97 && value <= 122

            if isDigit || isUpper || isLower {
                current.append(Character(scalar))
            } else if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            parts.append(current)
        }

        let normalized = parts
            .map { $0.uppercased() }
            .joined(separator: "_")

        guard !normalized.isEmpty else { throw CaseNameValidationError.empty }
        guard normalized.count <= maxNormalizedLength else {
            throw CaseNameValidationError.normalizedTooLong
        }
        guard let first = normalized.unicodeScalars.first, !(first.value >= 48 && first.value <= 57) else {
            throw CaseNameValidationError.leadingDigit
        }
        return normalized
    }

    /// Schema-1 vaults allowed a leading digit, which cannot be an
    /// environment variable name. Migration keeps such keys by prefixing `_`
    /// (kept within the length limit) instead of dropping them.
    static func repairedLegacyName(_ name: String) -> String {
        guard let first = name.unicodeScalars.first, first.value >= 48 && first.value <= 57 else { return name }
        return String(("_" + name).prefix(maxNormalizedLength))
    }

    /// `base`, or `base_2`, `base_3`… shortened to fit `maxNormalizedLength`,
    /// whichever is not in `taken` (uppercased names).
    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        var candidate = base
        var n = 2
        while taken.contains(candidate.uppercased()) {
            let suffix = "_\(n)"
            candidate = String(base.prefix(maxNormalizedLength - suffix.count)) + suffix
            n += 1
        }
        return candidate
    }

    static func isDuplicate(_ raw: String, existingNames: [String]) throws -> Bool {
        let normalized = try normalizedName(raw)
        return existingNames.contains {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }
}
