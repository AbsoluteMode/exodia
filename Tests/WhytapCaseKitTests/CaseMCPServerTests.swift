import XCTest
@testable import WhytapCaseKit

private final class FakeBroker: CaseBrokerCalling {
    var response: Result<CaseBrokerResponse, Error>
    var requests: [CaseBrokerRequest] = []
    init(_ r: Result<CaseBrokerResponse, Error>) { response = r }
    func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse {
        requests.append(request); return try response.get()
    }
}

final class CaseMCPServerTests: XCTestCase {
    private func server(_ b: CaseBrokerCalling?, path: String = "/Applications/Whytap.app/Contents/MacOS/whytap") -> CaseMCPServer {
        CaseMCPServer(client: b, executablePath: path)
    }
    private func json(_ s: String?) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(s).utf8)) as? [String: Any])
    }

    func test_initialize_returns_instructions() throws {
        let r = try json(server(nil).handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#))
        let res = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(res["protocolVersion"] as? String, "2024-11-05")
        XCTAssertEqual((res["serverInfo"] as? [String: Any])?["name"] as? String, "whytap-case")
        let ins = try XCTUnwrap(res["instructions"] as? String)
        XCTAssertTrue(ins.contains("/Applications/Whytap.app/Contents/MacOS/whytap case run --only KEY_NAME '<command using $KEY_NAME>'"))
        XCTAssertTrue(ins.hasPrefix("Whytap Case keeps secrets on this Mac."))
    }

    func test_instructions_quote_path_with_spaces() {
        XCTAssertTrue(server(nil, path: "/Users/a b/Whytap.app/x").instructions.contains("'/Users/a b/Whytap.app/x' case run"))
    }

    func test_tools_list_has_two_tools() throws {
        let r = try json(server(nil).handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }.sorted(), ["case_list_keys", "case_list_projects"])
    }

    func test_list_keys_output_has_no_values() throws {
        let b = FakeBroker(.success(.keys([CaseKeyInfo(name: "OPENAI_KEY", description: "main", project: "App")])))
        let line = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"case_list_keys","arguments":{"project":"App"}}}"#
        let out = try XCTUnwrap(server(b).handle(line: line))
        XCTAssertFalse(out.contains("sk-secret-123"))
        XCTAssertTrue(out.contains("OPENAI_KEY — main"))
        XCTAssertEqual(b.requests, [.listKeys(project: "App")])
        // even if a broker misbehaves and returns an environment, nothing is rendered
        let evil = FakeBroker(.success(.runEnvironment(["K": "sk-secret-123"])))
        let out2 = try XCTUnwrap(server(evil).handle(line: line))
        XCTAssertFalse(out2.contains("sk-secret-123"))
        XCTAssertEqual(try json(out2)["result"].flatMap { ($0 as? [String: Any])?["isError"] as? Bool }, true)
    }

    func test_query_finds_keys_directly_across_authorized_metadata_without_requesting_values() throws {
        let b = FakeBroker(.success(.keys([
            CaseKeyInfo(name: "SONIOX_API_KEY", description: "Speech", project: "App"),
            CaseKeyInfo(name: "TOKEN", description: "déploiement", project: "Backend"),
            CaseKeyInfo(name: "OTHER", description: "unrelated", project: "App"),
        ])))
        let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"case_list_keys","arguments":{"query":"backend deploiement"}}}"#
        let out = try XCTUnwrap(server(b).handle(line: call))
        XCTAssertTrue(out.contains("TOKEN — déploiement [Backend]"))
        XCTAssertFalse(out.contains("SONIOX_API_KEY"))
        XCTAssertFalse(out.contains("OTHER"))
        XCTAssertEqual(b.requests, [.listKeys(project: nil)])
        let nameCall = call.replacingOccurrences(of: "backend deploiement", with: "soniox")
        XCTAssertTrue(try XCTUnwrap(server(b).handle(line: nameCall)).contains("SONIOX_API_KEY"))
        let emptyCall = call.replacingOccurrences(of: "backend deploiement", with: "absent")
        XCTAssertTrue(try XCTUnwrap(server(b).handle(line: emptyCall)).contains("No matching keys."))
    }

    func test_list_projects_includes_key_count() throws {
        let b = FakeBroker(.success(.projects([CaseProjectInfo(name: "App", description: "my\napp", keyCount: 2)])))
        let out = try XCTUnwrap(server(b).handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"case_list_projects"}}"#))
        XCTAssertTrue(out.contains("App — my app (2 keys)"))
    }

    func test_denial_and_missing_app_are_error_results_not_crashes() throws {
        let call = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"case_list_projects"}}"#
        for s in [server(FakeBroker(.success(.denied(reason: .notRegistered)))),
                  server(FakeBroker(.failure(CaseBrokerClientError.unavailable))),
                  server(nil)] {
            let res = try XCTUnwrap(try json(s.handle(line: call))["result"] as? [String: Any])
            XCTAssertEqual(res["isError"] as? Bool, true)
        }
    }

    func test_unknown_method_returns_jsonrpc_error() throws {
        let r = try json(server(nil).handle(line: #"{"jsonrpc":"2.0","id":9,"method":"nope"}"#))
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual(r["id"] as? Int, 9)
    }

    func test_malformed_json_returns_parse_error_and_server_keeps_going() throws {
        let s = server(nil)
        var input = ["{not json", #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, "",
                     #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#]
        var out: [String] = []
        s.run(readLine: { input.isEmpty ? nil : input.removeFirst() }, write: { out.append($0) })
        XCTAssertEqual(out.count, 2) // parse error + ping; notification silent
        XCTAssertEqual((try json(out[0])["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertNotNil(try json(out[1])["result"])
    }
}
