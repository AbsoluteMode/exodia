import XCTest
@testable import WhytapCaseKit

final class AppControlMCPServerTests: XCTestCase {
    func testScreenServerExposesOnlyCaptureAndReturnsImageContent() throws {
        let server = AppControlMCPServer(screenOnly: true) { request in
            XCTAssertEqual(request, AppControlRequest("capture_screen"))
            return .success(.object(["image": .string("aW1hZ2U="), "mimeType": .string("image/jpeg"), "width": .int(32)]))
        }
        let listing = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        XCTAssertTrue(listing.contains("whytap_capture_screen"))
        XCTAssertFalse(listing.contains("whytap_set_model"))
        let reply = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"whytap_capture_screen"}}"#))
        let json = try JSONDecoder().decode(AppControlValue.self, from: Data(reply.utf8))
        guard case .array(let content) = json.object?["result"]?.object?["content"] else { return XCTFail("Missing content") }
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1].object?["type"], .string("image"))
        XCTAssertEqual(content[1].object?["data"], .string("aW1hZ2U="))
        XCTAssertFalse(content[0].object?["text"]?.string?.contains("aW1hZ2U=") == true)
        XCTAssertNil(json.object?["result"]?.object?["structuredContent"], "Do not duplicate image bytes into text/context")
    }

    func testScreenAndSettingsToolsCannotCrossScopes() throws {
        for screenOnly in [true, false] {
            let server = AppControlMCPServer(screenOnly: screenOnly) { _ in XCTFail("Wrong scope"); return .success(.null) }
            let name = screenOnly ? "whytap_set_setting" : "whytap_capture_screen"
            let request: AppControlValue = .object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
                "params": .object(["name": .string(name)])])
            let reply = try XCTUnwrap(server.handle(line: String(decoding: try JSONEncoder().encode(request), as: UTF8.self)))
            XCTAssertTrue(reply.contains("Unknown tool"))
        }
    }

    private final class Client: CaseBrokerCalling {
        var requests: [CaseBrokerRequest] = []
        func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse {
            requests.append(request)
            return .appControl(.success(.object(["build": .string("test-build")])) )
        }
    }

    func test_stdio_handshake_and_tools_work_without_launching_app() throws {
        let server = AppControlMCPServer { _ in XCTFail("metadata must not contact the app"); return .success(.null) }
        let hello = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        let json = try JSONDecoder().decode(AppControlValue.self, from: Data(hello.utf8))
        XCTAssertEqual(json.object?["result"]?.object?["protocolVersion"], .string("2025-06-18"))
        let listing = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        XCTAssertTrue(listing.contains("whytap_set_model"))
        XCTAssertFalse(listing.contains("case_list_keys"))
        XCTAssertFalse(listing.contains("resolveRun"))
    }

    func test_notifications_bad_ids_and_unknown_tools_never_invoke_app() {
        var calls = 0
        let server = AppControlMCPServer { _ in calls += 1; return .success(.null) }
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"whytap_set_setting"}}"#))
        for invalid in [
            #"{"jsonrpc":"2.0","id":true,"method":"tools/call","params":{"name":"whytap_set_setting"}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"case_list_keys"}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whytap_set_setting","arguments":[]}}"#,
            #"{"id":1,"method":"tools/call","params":{"name":"whytap_get_state"}}"#,
            String(repeating: "x", count: 33_000)
        ] { XCTAssertNotNil(server.handle(line: invalid)) }
        XCTAssertEqual(calls, 0)
    }

    func test_tools_send_only_namespaced_app_requests_and_return_structured_error() throws {
        let client = Client()
        let command = AppControlCommand(client: client)
        let server = AppControlMCPServer(call: command.call)
        let reply = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"whytap_get_state"}}"#))
        XCTAssertEqual(client.requests, [.appControl(AppControlRequest("get_state"))])
        XCTAssertTrue(reply.contains("structuredContent"))
        XCTAssertTrue(reply.contains("test-build"))
        let unavailable = AppControlMCPServer(call: AppControlCommand(client: nil).call)
        let error = try XCTUnwrap(unavailable.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whytap_get_state"}}"#))
        XCTAssertTrue(error.contains("\"isError\":true"))
    }

    func test_command_rejects_non_object_args_without_contacting_app() {
        let client = Client()
        let command = AppControlCommand(client: client)
        XCTAssertEqual(command.run(args: ["set-setting", "[]"], write: { _ in }), 2)
        XCTAssertEqual(command.run(args: ["run", "pwd"], write: { _ in }), 2)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func test_wire_roundtrip_does_not_confuse_booleans_integers_or_null() throws {
        let request = CaseBrokerRequest.appControl(AppControlRequest("set_setting", arguments: [
            "key": .string("autoHideIsland"), "value": .bool(false), "expected": .bool(true), "count": .int(1), "empty": .null
        ]))
        let bytes = try CaseBrokerCodec.encodeLine(request)
        XCTAssertEqual(try CaseBrokerCodec.decodeLine(CaseBrokerRequest.self, from: bytes), request)
    }

    func test_stdio_cancellation_is_read_while_a_tool_call_is_waiting() {
        let started = DispatchSemaphore(value: 0)
        let server = AppControlMCPServer(cancellableCall: { _, cancellation in
            started.signal()
            let deadline = Date().addingTimeInterval(2)
            while cancellation?.isCancelled != true && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            XCTAssertTrue(cancellation?.isCancelled == true)
            return .success(.null)
        })
        var index = 0
        var replies: [String] = []
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whytap_set_model"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
        ]
        server.run(readLine: {
            if index == 1 { XCTAssertEqual(started.wait(timeout: .now() + 2), .success) }
            guard index < lines.count else { return nil }
            defer { index += 1 }
            return lines[index]
        }, write: { replies.append($0) })
        XCTAssertEqual(replies.count, 1)
        XCTAssertTrue(replies.first?.contains("\"id\":2") == true)
    }

    func test_cancellation_before_connect_does_not_send_a_request() {
        let cancellation = AppControlCancellation()
        cancellation.cancel()
        let client = UnixSocketBrokerClient(socketURL: URL(fileURLWithPath: "/tmp/no-such-control-test-socket"))
        XCTAssertThrowsError(try client.send(.appControl(AppControlRequest("get_state")), cancellation: cancellation)) {
            XCTAssertEqual($0 as? CaseBrokerClientError, .protocolFailure)
        }
    }
}
