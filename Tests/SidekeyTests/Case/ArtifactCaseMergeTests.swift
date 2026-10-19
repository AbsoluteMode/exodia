import XCTest
@testable import Sidekey

/// Restoring a backup into an existing vault: names must stay unique, since the
/// broker looks keys and projects up by name. Values are obviously fake.
final class ArtifactCaseMergeTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func project(_ name: String, id: UUID = UUID(), at offset: TimeInterval = 0) -> CaseProject {
        CaseProject(id: id, name: name, description: "", createdAt: t0 + offset, updatedAt: t0 + offset)
    }

    private func secret(_ name: String, in projectID: UUID, id: UUID = UUID(), at offset: TimeInterval = 0) -> CaseSecret {
        CaseSecret(id: id, name: name, projectID: projectID, description: "", copyCount: 0, lastCopiedAt: nil,
                   createdAt: t0 + offset, updatedAt: t0 + offset)
    }

    private func payload(_ projects: [CaseProject], _ secrets: [(CaseSecret, String)]) -> CaseVaultPayload {
        CaseVaultPayload(projects: [.general(now: t0)] + projects, secrets: secrets.map(\.0),
                         values: secrets.map { CaseSecretValue(secretID: $0.0.id, value: $0.1) })
    }

    func test_same_key_name_with_different_ids_is_renamed_on_merge() throws {
        let alpha = project("alpha")
        let local = secret("DB_URL", in: alpha.id)
        let incoming = secret("DB_URL", in: alpha.id, at: 10)
        let general = secret("GH_TOKEN", in: CaseProject.generalID)
        let generalIncoming = secret("gh_token", in: CaseProject.generalID, at: 10)

        let merged = ArtifactCaseMerge.merge(
            source: payload([alpha], [(incoming, "fake-backup-db"), (generalIncoming, "fake-backup-gh")]),
            into: payload([alpha], [(local, "fake-local-db"), (general, "fake-local-gh")]))

        XCTAssertEqual(merged.secrets.first { $0.id == local.id }?.name, "DB_URL", "this Mac keeps its name")
        XCTAssertEqual(merged.secrets.first { $0.id == incoming.id }?.name, "DB_URL_2")
        XCTAssertEqual(merged.secrets.first { $0.id == generalIncoming.id }?.name, "gh_token_2",
                       "names clash case-insensitively")
        XCTAssertEqual(merged.value(for: local.id), "fake-local-db")
        XCTAssertEqual(merged.value(for: incoming.id), "fake-backup-db")
        Self.assertUniqueNames(merged)
    }

    func test_same_project_name_with_different_ids_is_renamed_on_merge() throws {
        let localAlpha = project("alpha")
        let incomingAlpha = project("Alpha", at: 5)
        let incomingAlpha2 = project("alpha (2)", at: 6)
        let localKey = secret("DB_URL", in: localAlpha.id)
        let incomingKey = secret("DB_URL", in: incomingAlpha.id, at: 10)
        let generalTwin = project("general", at: 7)

        let merged = ArtifactCaseMerge.merge(
            source: payload([incomingAlpha, incomingAlpha2, generalTwin], [(incomingKey, "fake-backup-db")]),
            into: payload([localAlpha], [(localKey, "fake-local-db")]))

        XCTAssertEqual(merged.project(localAlpha.id)?.name, "alpha")
        let names = Set(merged.projects.map { $0.name.lowercased() })
        XCTAssertEqual(names.count, merged.projects.count, "no two projects share a name")
        XCTAssertEqual(merged.project(incomingAlpha.id)?.name, "Alpha (3)", "(2) is already taken by the backup")
        XCTAssertEqual(merged.project(incomingAlpha2.id)?.name, "alpha (2)")
        XCTAssertEqual(merged.project(generalTwin.id)?.name, "general (2)")
        XCTAssertEqual(merged.project(CaseProject.generalID)?.name, "General")
        // Keys stay in their own (renamed) project.
        XCTAssertEqual(merged.secrets.first { $0.id == incomingKey.id }?.projectID, incomingAlpha.id)
        XCTAssertEqual(merged.secrets.first { $0.id == incomingKey.id }?.name, "DB_URL")
        Self.assertUniqueNames(merged)
    }

    func test_renamed_long_names_stay_within_limits() throws {
        let long = String(repeating: "p", count: CaseProject.maxNameCharacters)
        let key = "K" + String(repeating: "E", count: CaseNameNormalizer.maxNormalizedLength - 1)
        let local = project(long), incoming = project(long, at: 5)
        let merged = ArtifactCaseMerge.merge(
            source: payload([incoming], [(secret(key, in: CaseProject.generalID, at: 9), "fake-b")]),
            into: payload([local], [(secret(key, in: CaseProject.generalID), "fake-a")]))
        let renamed = try XCTUnwrap(merged.project(incoming.id)?.name)
        XCTAssertEqual(renamed.count, CaseProject.maxNameCharacters)
        XCTAssertTrue(renamed.hasSuffix(" (2)"))
        XCTAssertTrue(merged.secrets.allSatisfy { $0.name.count <= CaseNameNormalizer.maxNormalizedLength })
        XCTAssertTrue(merged.secrets.contains { $0.name.hasSuffix("_2") })
        Self.assertUniqueNames(merged)
    }

    func test_same_id_newer_backup_keeps_its_name_when_nothing_clashes() throws {
        let alpha = project("alpha")
        var renamedInBackup = alpha
        renamedInBackup.name = "alpha-web"
        renamedInBackup.updatedAt = t0 + 100
        let merged = ArtifactCaseMerge.merge(source: payload([renamedInBackup], []),
                                             into: payload([alpha], []))
        XCTAssertEqual(merged.project(alpha.id)?.name, "alpha-web")
    }

    static func assertUniqueNames(_ payload: CaseVaultPayload, file: StaticString = #filePath, line: UInt = #line) {
        let projectNames = payload.projects.map { $0.name.lowercased() }
        XCTAssertEqual(Set(projectNames).count, projectNames.count, "project names", file: file, line: line)
        for project in payload.projects {
            let keys = payload.secrets.filter { $0.projectID == project.id }.map { $0.name.uppercased() }
            XCTAssertEqual(Set(keys).count, keys.count, "keys of \(project.name)", file: file, line: line)
        }
    }
}
