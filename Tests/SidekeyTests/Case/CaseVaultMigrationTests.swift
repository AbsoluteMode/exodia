import CryptoKit
import XCTest
@testable import Sidekey

final class CaseVaultMigrationTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private static let aad = Data("com.rootwise.sidekey.case-vault.v1".utf8)

    // MARK: v1 fixtures (the exact schema-1 shape)

    private struct V1Secret: Encodable {
        var id: UUID
        var name: String
        var groupID: UUID?
        var copyCount = 0
        var lastCopiedAt: Date?
        var createdAt: Date
        var updatedAt: Date
    }
    private struct V1Group: Encodable {
        var id: UUID
        var name: String
        var keyIDs: [UUID]
        var copyCount = 0
        var lastCopiedAt: Date?
        var createdAt: Date
        var updatedAt: Date
    }
    private struct V1Payload: Encodable {
        var schemaVersion = 1
        var secrets: [V1Secret]
        var values: [CaseSecretValue]
        var groups: [V1Group]
    }

    static func v1Plaintext(secrets: [(id: UUID, name: String, group: UUID?)],
                            groups: [(id: UUID, name: String, keys: [UUID])] = [],
                            at date: Date) throws -> Data {
        let v1Secrets = secrets.map {
            V1Secret(id: $0.id, name: $0.name, groupID: $0.group, createdAt: date, updatedAt: date)
        }
        let values = secrets.map { CaseSecretValue(secretID: $0.id, value: "value-of-\($0.name)") }
        let v1Groups = groups.map {
            V1Group(id: $0.id, name: $0.name, keyIDs: $0.keys, createdAt: date, updatedAt: date)
        }
        return try JSONEncoder.caseVault.encode(V1Payload(secrets: v1Secrets, values: values, groups: v1Groups))
    }

    private func v1(_ secrets: [(id: UUID, name: String, group: UUID?)],
                    groups: [(id: UUID, name: String, keys: [UUID])] = []) throws -> Data {
        try Self.v1Plaintext(secrets: secrets, groups: groups, at: t0)
    }

    private func s(_ name: String, group: UUID? = nil) -> (id: UUID, name: String, group: UUID?) {
        (UUID(), name, group)
    }

    // MARK: migration

    func test_v1_ungrouped_secrets_move_to_general() throws {
        let a = s("OPENAI_KEY"), b = s("STRIPE_KEY")
        let payload = try CaseVaultMigration.decodePayload(try v1([a, b]))

        XCTAssertEqual(payload.schemaVersion, CaseVaultPayload.currentSchemaVersion)
        XCTAssertEqual(payload.projects.first?.id, CaseProject.generalID)
        XCTAssertEqual(payload.projects.count, 1)
        XCTAssertEqual(payload.secrets.map(\.projectID), [CaseProject.generalID, CaseProject.generalID])
        XCTAssertEqual(payload.value(for: a.id), "value-of-OPENAI_KEY")
        XCTAssertEqual(payload.value(for: b.id), "value-of-STRIPE_KEY")
        XCTAssertEqual(payload.secrets.map(\.description), ["", ""])
        XCTAssertEqual(payload.apps, [])
        XCTAssertEqual(payload.timedApprovalMinutes, 15)
    }

    func test_v1_groups_become_projects_with_same_name() throws {
        let gid = UUID()
        let a = s("SSH_USER", group: gid), b = s("SSH_PASS", group: gid)
        let payload = try CaseVaultMigration.decodePayload(
            try v1([a, b], groups: [(gid, "servers", [a.id, b.id])]))

        let project = try XCTUnwrap(payload.projects.first { $0.name == "servers" })
        XCTAssertEqual(payload.projects.count, 2)
        XCTAssertEqual(payload.secrets.map(\.projectID), [project.id, project.id])
    }

    func test_v1_group_membership_via_keyIDs_alone_is_kept() throws {
        let gid = UUID()
        let a = s("A_KEY")
        let payload = try CaseVaultMigration.decodePayload(try v1([a], groups: [(gid, "legacy", [a.id])]))
        XCTAssertEqual(payload.secrets.first?.projectID, gid)
    }

    func test_v1_group_named_general_merges_into_builtin_general() throws {
        let gid = UUID()
        let a = s("K1", group: gid), b = s("K2")
        let payload = try CaseVaultMigration.decodePayload(
            try v1([a, b], groups: [(gid, "general", [a.id])]))

        XCTAssertEqual(payload.projects.map(\.id), [CaseProject.generalID])
        XCTAssertEqual(payload.projects.first?.name, "General")
        XCTAssertEqual(payload.secrets.map(\.projectID), [CaseProject.generalID, CaseProject.generalID])
    }

    func test_v1_leading_digit_names_are_repaired_not_dropped() throws {
        let a = s("1PASSWORD")
        let payload = try CaseVaultMigration.decodePayload(try v1([a]))
        XCTAssertEqual(payload.secrets.first?.name, "_1PASSWORD")
        XCTAssertEqual(payload.value(for: a.id), "value-of-1PASSWORD")
    }

    func test_v1_repaired_name_that_already_exists_gets_suffix() throws {
        let existing = s("_1PASSWORD"), digit = s("1PASSWORD")
        // The repaired key is listed first: it still must not steal the existing name.
        let payload = try CaseVaultMigration.decodePayload(try v1([digit, existing]))
        XCTAssertEqual(payload.secrets.map(\.name), ["_1PASSWORD_2", "_1PASSWORD"])
    }

    func test_v1_groups_equal_after_truncation_become_distinct_projects() throws {
        let stem = String(repeating: "infrastructure-", count: 4) // 60 chars, truncated to 48
        let g1 = UUID(), g2 = UUID(), g3 = UUID()
        let a = s("A_KEY", group: g1), b = s("B_KEY", group: g2), c = s("C_KEY", group: g3)
        let payload = try CaseVaultMigration.decodePayload(try v1([a, b, c], groups: [
            (g1, stem + "prod", [a.id]), (g2, stem + "staging", [b.id]), (g3, stem + "PROD", [c.id]),
        ]))

        let names = payload.projects.map(\.name)
        XCTAssertEqual(Set(names.map { $0.lowercased() }).count, names.count, "no duplicate project names: \(names)")
        XCTAssertTrue(names.allSatisfy { $0.count <= CaseProject.maxNameCharacters })
        XCTAssertEqual(payload.projects.count, 3, "General + two projects (same full name merges as before)")
        let pa = try XCTUnwrap(payload.secrets.first { $0.id == a.id }?.projectID)
        let pb = try XCTUnwrap(payload.secrets.first { $0.id == b.id }?.projectID)
        let pc = try XCTUnwrap(payload.secrets.first { $0.id == c.id }?.projectID)
        XCTAssertNotEqual(pa, pb, "different groups stay apart")
        XCTAssertEqual(pa, pc, "group names equal ignoring case still merge")
        XCTAssertEqual(payload.project(pa)?.name, String((stem + "prod").prefix(48)))
        XCTAssertEqual(payload.project(pb)?.name.hasSuffix(" (2)"), true)
    }

    func test_repairedLegacyName_prefixes_only_leading_digit() {
        XCTAssertEqual(CaseNameNormalizer.repairedLegacyName("1PASSWORD"), "_1PASSWORD")
        XCTAssertEqual(CaseNameNormalizer.repairedLegacyName("OPENAI"), "OPENAI")
        XCTAssertLessThanOrEqual(CaseNameNormalizer.repairedLegacyName("1" + String(repeating: "A", count: 63)).count, 64)
    }

    // MARK: v2 and newer

    func test_v2_round_trips_unchanged() throws {
        let pid = UUID()
        let sid = UUID()
        let original = CaseVaultPayload(
            projects: [.general(now: t0), CaseProject(id: pid, name: "Prod", description: "live", createdAt: t0, updatedAt: t0)],
            secrets: [CaseSecret(id: sid, name: "DB_URL", projectID: pid, description: "main db",
                                 copyCount: 2, lastCopiedAt: t0, createdAt: t0, updatedAt: t0)],
            values: [CaseSecretValue(secretID: sid, value: "x")],
            apps: [CaseAppRegistration(id: UUID(), displayName: "Tool",
                                       identity: .developerID(teamID: "T", signingIdentifier: "s"),
                                       defaultMode: .approve, projectModes: [pid: .bypass], createdAt: t0)],
            timedApprovalMinutes: 30)
        let data = try JSONEncoder.caseVault.encode(original)
        XCTAssertEqual(try CaseVaultMigration.decodePayload(data), original)
    }

    func test_v2_missing_optional_keys_decode_to_defaults() throws {
        let original = CaseVaultPayload(
            secrets: [CaseSecret(id: UUID(), name: "K", projectID: CaseProject.generalID, description: "d",
                                 copyCount: 0, lastCopiedAt: nil, createdAt: t0, updatedAt: t0)])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.caseVault.encode(original)) as? [String: Any])
        object.removeValue(forKey: "apps")
        object.removeValue(forKey: "timedApprovalMinutes")
        var secrets = try XCTUnwrap(object["secrets"] as? [[String: Any]])
        secrets[0].removeValue(forKey: "description")
        object["secrets"] = secrets
        let payload = try CaseVaultMigration.decodePayload(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(payload.apps, [])
        XCTAssertEqual(payload.timedApprovalMinutes, 15)
        XCTAssertEqual(payload.secrets.first?.description, "")
    }

    func test_schema_2_registrations_keep_all_projects_and_schema_3_roundtrips_selected_scope() throws {
        let app = CaseAppRegistration(id: UUID(), displayName: "Codex", identity: CaseKnownClient.codex.identity,
                                      defaultMode: .approve, projectModes: [:], createdAt: t0)
        let legacy = CaseVaultPayload(schemaVersion: 2, apps: [app])
        let migrated = try CaseVaultMigration.decodePayload(JSONEncoder.caseVault.encode(legacy))
        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertNil(migrated.apps.first?.allowedProjectIDs)
        var scoped = migrated
        scoped.apps[0].allowedProjectIDs = [CaseProject.generalID]
        let decoded = try CaseVaultMigration.decodePayload(JSONEncoder.caseVault.encode(scoped))
        XCTAssertEqual(decoded.apps[0].allowedProjectIDs, [CaseProject.generalID])
        scoped.apps[0].allowedProjectIDs = []
        let empty = try CaseVaultMigration.decodePayload(JSONEncoder.caseVault.encode(scoped))
        XCTAssertEqual(empty.apps[0].allowedProjectIDs, [])
    }

    func test_future_schema_throws_needsNewerApp() throws {
        let (store, key) = try storeWithPlaintext(Data(#"{"schemaVersion":4,"future":true}"#.utf8))
        XCTAssertThrowsError(try CaseVaultStore.decode(envelope: Data(contentsOf: store.fileURL), using: key)) {
            XCTAssertEqual($0 as? CaseVaultStoreError, .needsNewerApp)
        }
        XCTAssertThrowsError(try store.load(using: key)) {
            XCTAssertEqual($0 as? CaseVaultStoreError, .needsNewerApp)
        }
    }

    func test_store_loads_v1_file_and_save_writes_v2_keeping_v1_in_bak() throws {
        let a = s("OPENAI_KEY")
        let (store, key) = try storeWithPlaintext(try v1([a]))
        let v1Bytes = try Data(contentsOf: store.fileURL)

        let loaded = try store.load(using: key)
        XCTAssertEqual(loaded.schemaVersion, CaseVaultPayload.currentSchemaVersion)
        try store.save(loaded, using: key)

        XCTAssertEqual(try store.load(using: key), loaded)
        XCTAssertEqual(try Data(contentsOf: store.backupFileURL), v1Bytes)
        let backup = try CaseVaultMigration.decodePayload(try openPlaintext(of: store.backupFileURL, key: key))
        XCTAssertEqual(backup.secrets.first?.name, "OPENAI_KEY")
    }

    func test_first_v2_save_keeps_a_one_time_v1_copy() throws {
        let a = s("OPENAI_KEY")
        let (store, key) = try storeWithPlaintext(try v1([a]))
        let v1Bytes = try Data(contentsOf: store.fileURL)
        let v1Copy = store.fileURL.deletingLastPathComponent().appendingPathComponent("case-vault.json.enc.v1")

        var loaded = try store.load(using: key)
        try store.save(loaded, using: key)
        XCTAssertEqual(try Data(contentsOf: v1Copy), v1Bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: v1Copy.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        // Later saves rotate .bak but never touch the v1 copy.
        loaded.timedApprovalMinutes = 30
        try store.save(loaded, using: key)
        try store.save(loaded, using: key)
        XCTAssertEqual(try Data(contentsOf: v1Copy), v1Bytes)
        XCTAssertNotEqual(try Data(contentsOf: store.backupFileURL), v1Bytes, ".bak alone loses v1 after two saves")
        let kept = try CaseVaultMigration.decodePayload(try openPlaintext(of: v1Copy, key: key))
        XCTAssertEqual(kept.secrets.first?.name, "OPENAI_KEY")

        // A v1 copy that already exists is never overwritten.
        try Data("older copy".utf8).write(to: v1Copy)
        try Self.writeSealedVault(try v1([a]), key: key, to: store.fileURL)
        try store.save(try store.load(using: key), using: key)
        XCTAssertEqual(try Data(contentsOf: v1Copy), Data("older copy".utf8))
    }

    func test_v2_vault_never_gets_a_v1_copy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = CaseVaultStore(fileURL: dir.appendingPathComponent("case-vault.json.enc"))
        let key = SymmetricKey(size: .bits256)
        try store.save(CaseVaultPayload(), using: key)
        try store.save(CaseVaultPayload(), using: key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("case-vault.json.enc.v1").path))
    }

    // MARK: helpers

    private func storeWithPlaintext(_ plaintext: Data) throws -> (CaseVaultStore, SymmetricKey) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let url = dir.appendingPathComponent("case-vault.json.enc")
        try Self.writeSealedVault(plaintext, key: key, to: url)
        return (CaseVaultStore(fileURL: url), key)
    }

    /// Writes `plaintext` as a vault envelope exactly as the store would,
    /// without going through `save` (which always emits schema 2).
    static func writeSealedVault(_ plaintext: Data, key: SymmetricKey, to url: URL) throws {
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        let envelope = CaseVaultEnvelope(
            version: CaseVaultStore.envelopeVersion, algorithm: CaseVaultStore.algorithm,
            nonce: sealed.nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(), tag: sealed.tag.base64EncodedString())
        try JSONEncoder().encode(envelope).write(to: url)
    }

    private func openPlaintext(of url: URL, key: SymmetricKey) throws -> Data {
        let envelope = try JSONDecoder().decode(CaseVaultEnvelope.self, from: Data(contentsOf: url))
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: Data(base64Encoded: envelope.nonce)!),
            ciphertext: Data(base64Encoded: envelope.ciphertext)!, tag: Data(base64Encoded: envelope.tag)!)
        return try AES.GCM.open(box, using: key, authenticating: Self.aad)
    }
}
