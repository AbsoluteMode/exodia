import XCTest
@testable import Sidekey

final class CaseDopplerImporterTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func test_import_preserves_environments_empty_and_multiline_values_and_is_idempotent() throws {
        let snapshot = CaseDopplerSnapshot(configurations: [
            .init(project: "demo", config: "dev", secrets: ["API_KEY": "dev-fixture", "EMPTY": "",
                  "CERT": "line1\nline2\n", "DOPPLER_PROJECT": "demo"]),
            .init(project: "demo", config: "prd", secrets: ["API_KEY": "prod-fixture"])
        ])
        var payload = CaseVaultPayload()
        let result = try snapshot.merge(into: &payload, now: date)
        XCTAssertEqual(result, .init(configurations: 2, added: 4, unchanged: 0))
        XCTAssertEqual(payload.projects.map(\.name), ["General", "demo / dev", "demo / prd"])
        let devID = snapshot.configurations[0].projectID
        let dev = payload.secrets.filter { $0.projectID == devID }
        XCTAssertEqual(payload.value(for: try XCTUnwrap(dev.first { $0.name == "CERT" }).id), "line1\nline2\n")
        XCTAssertEqual(payload.value(for: try XCTUnwrap(dev.first { $0.name == "EMPTY" }).id), "")
        let original = payload
        XCTAssertEqual(try snapshot.merge(into: &payload, now: date), .init(configurations: 2, added: 0, unchanged: 4))
        XCTAssertEqual(payload, original)
    }

    func test_conflict_in_last_configuration_does_not_change_any_existing_data() throws {
        var snapshot = CaseDopplerSnapshot(configurations: [
            .init(project: "demo", config: "prd", secrets: ["API_KEY": "original-fixture"])
        ])
        var payload = CaseVaultPayload()
        _ = try snapshot.merge(into: &payload, now: date)
        let original = payload
        snapshot.configurations.insert(.init(project: "another", config: "dev", secrets: ["NEW": "fixture"]), at: 0)
        snapshot.configurations[1].secrets["API_KEY"] = "changed-fixture"
        XCTAssertThrowsError(try snapshot.merge(into: &payload, now: date)) {
            XCTAssertEqual($0 as? CaseDopplerImportError, .conflict)
        }
        XCTAssertEqual(payload, original)
    }

    func test_invalid_or_oversized_key_never_leaves_a_partial_import() throws {
        for invalid in [["BAD-NAME": "fixture"], ["1INVALID": "fixture"], ["KEY": String(repeating: "x", count: 16_385)]] {
            let snapshot = CaseDopplerSnapshot(configurations: [
                .init(project: "valid", config: "dev", secrets: ["VALID": "fixture"]),
                .init(project: "invalid", config: "prd", secrets: invalid)
            ])
            var payload = CaseVaultPayload()
            let original = payload
            XCTAssertThrowsError(try snapshot.merge(into: &payload, now: date))
            XCTAssertEqual(payload, original)
        }
    }

    func test_existing_local_project_with_same_name_is_preserved_and_import_gets_unique_name() throws {
        var payload = CaseVaultPayload()
        let local = CaseProject(id: UUID(), name: "demo / dev", description: "local", createdAt: date, updatedAt: date)
        payload.projects.append(local)
        _ = try CaseDopplerSnapshot(configurations: [.init(project: "demo", config: "dev", secrets: ["KEY": "fixture"])])
            .merge(into: &payload, now: date)
        XCTAssertEqual(payload.projects[1], local)
        XCTAssertEqual(payload.projects[2].name, "demo / dev (2)")
    }

    func test_cli_fetch_reads_every_page_and_disables_plaintext_fallbacks() async throws {
        var calls: [[String]] = []
        let importer = CaseDopplerImporter { arguments in
            calls.append(arguments)
            if arguments.first == "projects" {
                return arguments.last == "1"
                    ? try JSONSerialization.data(withJSONObject: (0..<100).map { ["id": "p\($0)"] })
                    : Data("[]".utf8)
            }
            if arguments.first == "configs" { return Data("[{\"name\":\"dev\"}]".utf8) }
            XCTAssertTrue(arguments.contains("--no-fallback"))
            XCTAssertTrue(arguments.contains("--no-file"))
            return Data("{\"KEY\":\"fixture\"}".utf8)
        }
        let snapshot = try await importer.fetch()
        XCTAssertEqual(snapshot.configurations.count, 100)
        XCTAssertEqual(calls.filter { $0.first == "projects" }.count, 2)
        XCTAssertEqual(calls.filter { $0.first == "secrets" }.count, 100)
    }

    func test_cli_errors_never_expose_provider_output() async {
        let importer = CaseDopplerImporter { _ in
            throw NSError(domain: "private-fixture-value", code: 1)
        }
        do {
            _ = try await importer.fetch()
            XCTFail("Expected sanitized error")
        } catch {
            XCTAssertEqual(error as? CaseDopplerImportError, .fetchFailed)
            XCTAssertFalse(String(describing: error).contains("private-fixture-value"))
        }
    }

    func test_cancellation_does_not_become_a_fetch_error() async {
        let importer = CaseDopplerImporter { _ in throw CancellationError() }
        do {
            _ = try await importer.fetch()
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
