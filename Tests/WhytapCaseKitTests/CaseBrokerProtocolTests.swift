import XCTest
@testable import WhytapCaseKit

final class CaseBrokerProtocolTests: XCTestCase {
    func test_requests_and_responses_round_trip_as_single_json_lines() throws {
        let requests: [CaseBrokerRequest] = [
            .listProjects,
            .listKeys(project: nil),
            .listKeys(project: "My\nProject"),
            .resolveRun(project: "App", only: ["A_B", "C"], command: "echo \"hi\"\nls", cwd: "/tmp/a b"),
            .resolveRun(project: nil, only: nil, command: "", cwd: "")
        ]
        for r in requests {
            let line = try CaseBrokerCodec.encodeLine(r)
            XCTAssertEqual(line.last, 0x0A)
            XCTAssertFalse(line.dropLast().contains(0x0A), "newline inside payload")
            XCTAssertEqual(try CaseBrokerCodec.decodeLine(CaseBrokerRequest.self, from: line), r)
        }
        let p = CaseProjectInfo(name: "A", description: "line1\nline2", keyCount: 2)
        let responses: [CaseBrokerResponse] = [
            .projects([p]), .projects([]),
            .keys([CaseKeyInfo(name: "K", description: "d", project: "A")]),
            .runEnvironment(["K": "multi\nline\u{2028}value"]),
            .ambiguous(key: "K", projects: [p]),
            .denied(reason: .touchIDFailed)
        ]
        for r in responses {
            let line = try CaseBrokerCodec.encodeLine(r)
            XCTAssertFalse(line.dropLast().contains(0x0A))
            XCTAssertEqual(try CaseBrokerCodec.decodeLine(CaseBrokerResponse.self, from: line), r)
        }
    }

    func test_garbage_and_unknown_deny_reason_fail_to_decode() {
        XCTAssertThrowsError(try CaseBrokerCodec.decodeLine(CaseBrokerRequest.self, from: Data("nope\n".utf8)))
        XCTAssertThrowsError(try CaseBrokerCodec.decodeLine(CaseBrokerRequest.self, from: Data()))
        XCTAssertThrowsError(try CaseBrokerCodec.decodeLine(
            CaseBrokerResponse.self, from: Data(#"{"denied":{"reason":"bogus"}}"#.utf8)))
    }

    func test_socket_path_is_under_bundle_application_support_and_shorter_than_104_bytes() {
        let url = CaseBrokerPaths.socketURL(bundleID: "com.rootwise.sidekey")
        XCTAssertTrue(url.path.contains("/Library/Application Support/com.rootwise.sidekey/"))
        XCTAssertEqual(url.lastPathComponent, "case-broker.sock")
        XCTAssertLessThan(url.path.utf8.count, 104)

        let short = CaseBrokerPaths.socketURL(bundleID: "com.rootwise.sidekey.beta", home: URL(fileURLWithPath: "/Users/m"))
        XCTAssertEqual(short.path, "/Users/m/Library/Application Support/com.rootwise.sidekey.beta/case-broker.sock")
    }

    func test_long_home_directory_falls_back_to_short_socket_name() {
        // Full name is 7 bytes longer than the fallback; pick a home that only fits the fallback.
        let bundle = "com.rootwise.sidekey"
        let fixed = "/Library/Application Support/\(bundle)/".utf8.count
        let homeLen = CaseBrokerPaths.maxSocketPathBytes - fixed - "cb.sock".utf8.count
        let home = URL(fileURLWithPath: "/" + String(repeating: "h", count: homeLen - 1))
        let url = CaseBrokerPaths.socketURL(bundleID: bundle, home: home)
        XCTAssertEqual(url.lastPathComponent, "cb.sock")
        XCTAssertLessThan(url.path.utf8.count, 104)
    }
}
