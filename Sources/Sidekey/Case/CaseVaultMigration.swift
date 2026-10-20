import Foundation

/// Reads a decrypted vault of any supported schema and returns schema 2.
///
/// Schema 1 had secrets and groups; schema 2 has projects. Migration never
/// drops a key or a value: ungrouped keys go to the built-in General, each
/// group becomes a project of the same name, and a name that is no longer
/// valid (a leading digit) is repaired instead of discarded.
/// WHY: docs/superpowers/specs/2026-10-19-case-secrets-manager-design.md
enum CaseVaultMigration {
    static func decodePayload(_ plaintext: Data) throws -> CaseVaultPayload {
        let decoder = JSONDecoder.caseVault
        let probe = try decoder.decode(SchemaProbe.self, from: plaintext)
        switch probe.schemaVersion {
        case 1:
            return migrate(try decoder.decode(LegacyPayload.self, from: plaintext))
        case 2:
            var payload = try decoder.decode(CaseVaultPayload.self, from: plaintext)
            if !payload.projects.contains(where: { $0.id == CaseProject.generalID }) {
                payload.projects.insert(.general(now: payload.secrets.map(\.createdAt).min()
                    ?? Date(timeIntervalSinceReferenceDate: 0)), at: 0)
            }
            return payload
        case let version where version > CaseVaultPayload.currentSchemaVersion:
            throw CaseVaultStoreError.needsNewerApp
        default:
            throw CaseVaultStoreError.unsupportedEnvelope
        }
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    private struct LegacySecret: Decodable {
        var id: UUID
        var name: String
        var groupID: UUID?
        var copyCount: Int
        var lastCopiedAt: Date?
        var createdAt: Date
        var updatedAt: Date
    }

    private struct CaseGroup: Decodable {
        var id: UUID
        var name: String
        var keyIDs: [UUID]
        var createdAt: Date
        var updatedAt: Date
    }

    private struct LegacyPayload: Decodable {
        var secrets: [LegacySecret]
        var values: [CaseSecretValue]
        var groups: [CaseGroup]
    }

    private static func migrate(_ legacy: LegacyPayload) -> CaseVaultPayload {
        let earliest = (legacy.secrets.map(\.createdAt) + legacy.groups.map(\.createdAt)).min()
            ?? Date(timeIntervalSinceReferenceDate: 0)
        var projects = [CaseProject.general(now: earliest)]
        var groupToProject: [UUID: UUID] = [:]
        // Groups with the same full name (any case) share a project, as before.
        // A different group whose name only collides after truncation to 48
        // characters gets its own, suffixed name instead.
        var projectForFullName: [String: UUID] = [CaseProject.generalName.lowercased(): CaseProject.generalID]
        var takenNames: Set<String> = [CaseProject.generalName.lowercased()]

        for group in legacy.groups {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                groupToProject[group.id] = CaseProject.generalID
            } else if let existing = projectForFullName[name.lowercased()] {
                groupToProject[group.id] = existing
            } else {
                let unique = CaseProject.uniqueName(name, taken: takenNames)
                takenNames.insert(unique.lowercased())
                projectForFullName[name.lowercased()] = group.id
                projects.append(CaseProject(
                    id: group.id,
                    name: unique,
                    description: "",
                    createdAt: group.createdAt,
                    updatedAt: group.updatedAt))
                groupToProject[group.id] = group.id
            }
        }

        var memberOf: [UUID: UUID] = [:]
        for group in legacy.groups {
            for keyID in group.keyIDs { memberOf[keyID] = groupToProject[group.id] }
        }

        func projectID(for secret: LegacySecret) -> UUID {
            if let groupID = secret.groupID, let mapped = groupToProject[groupID] { return mapped }
            return memberOf[secret.id] ?? CaseProject.generalID
        }

        // Names that are already valid claim their slot first, so a repaired
        // name can never take a name another key of that project owns.
        var taken: [UUID: Set<String>] = [:]
        for secret in legacy.secrets where !startsWithDigit(secret.name) {
            taken[projectID(for: secret), default: []].insert(secret.name.uppercased())
        }

        let secrets = legacy.secrets.map { secret -> CaseSecret in
            let project = projectID(for: secret)
            var name = secret.name
            if startsWithDigit(name) {
                name = CaseNameNormalizer.uniqueName(CaseNameNormalizer.repairedLegacyName(name),
                                                     taken: taken[project, default: []])
                taken[project, default: []].insert(name.uppercased())
            }
            return CaseSecret(
                id: secret.id, name: name, projectID: project, description: "",
                copyCount: secret.copyCount, lastCopiedAt: secret.lastCopiedAt,
                createdAt: secret.createdAt, updatedAt: secret.updatedAt)
        }

        return CaseVaultPayload(
            schemaVersion: CaseVaultPayload.currentSchemaVersion,
            projects: projects,
            secrets: secrets,
            values: legacy.values,
            apps: [],
            timedApprovalMinutes: CaseVaultPayload.defaultTimedApprovalMinutes)
    }

    private static func startsWithDigit(_ name: String) -> Bool {
        name.unicodeScalars.first.map { $0.value >= 48 && $0.value <= 57 } ?? false
    }
}
