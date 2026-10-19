import XCTest
@testable import WhytapCaseKit

private final class FakeBroker: CaseBrokerCalling {
    var response: CaseBrokerResponse
    var requests: [CaseBrokerRequest] = []
    init(_ r: CaseBrokerResponse) { response = r }
    func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse {
        requests.append(request); return response
    }
}

final class MaskedProcessRunnerTests: XCTestCase {
    private let secret = "tok-fake-Zq81xw-notreal"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("case-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func capture(_ body: (FileHandle, FileHandle) throws -> Int32) rethrows -> (Int32, String, String) {
        let o = dir.appendingPathComponent("o\(UUID().uuidString)"), e = dir.appendingPathComponent("e\(UUID().uuidString)")
        FileManager.default.createFile(atPath: o.path, contents: nil)
        FileManager.default.createFile(atPath: e.path, contents: nil)
        let oh = try! FileHandle(forWritingTo: o), eh = try! FileHandle(forWritingTo: e)
        let code = try body(oh, eh)
        try? oh.close(); try? eh.close()
        return (code, (try? String(contentsOf: o)) ?? "", (try? String(contentsOf: e)) ?? "")
    }

    func test_child_sees_value_in_env_not_argv() throws {
        let (code, out, _) = try capture { o, e in
            try MaskedProcessRunner.run(
                command: "printf %s \"$X\" | wc -c | tr -d ' '; ps -o args= -p $$",
                environment: ["X": secret], cwd: dir, masker: CaseOutputMasker(secrets: [secret]),
                stdout: o, stderr: e)
        }
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.hasPrefix("\(secret.count)\n"), out)
        XCTAssertFalse(out.contains(secret))
    }

    func test_stdout_and_stderr_masked() throws {
        let (_, out, err) = try capture { o, e in
            try MaskedProcessRunner.run(
                command: "echo \"out $X\"; echo \"err $X\" >&2", environment: ["X": secret], cwd: dir,
                masker: CaseOutputMasker(secrets: [secret]), stdout: o, stderr: e)
        }
        XCTAssertEqual(out, "out [case:hidden]\n")
        XCTAssertEqual(err, "err [case:hidden]\n")
    }

    func test_exit_code_passthrough_and_cwd() throws {
        let (code, out, _) = try capture { o, e in
            try MaskedProcessRunner.run(command: "pwd -P; exit 7", environment: [:], cwd: dir,
                                        masker: CaseOutputMasker(secrets: []), stdout: o, stderr: e)
        }
        XCTAssertEqual(code, 7)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines),
                       URL(fileURLWithPath: "/private" + dir.path).path)
    }

    func test_ambiguous_response_exits_3_without_running() {
        let marker = dir.appendingPathComponent("ran")
        let broker = FakeBroker(.ambiguous(key: "API_KEY", projects: [
            CaseProjectInfo(name: "alpha", description: "Alpha app", keyCount: 1),
            CaseProjectInfo(name: "beta", description: "Beta app", keyCount: 1)]))
        let (code, _, err) = capture { o, e in
            CaseCommand(client: broker, cwd: dir, stdout: o, stderr: e)
                .run(args: ["case", "run", "touch \(marker.path)"])
        }
        XCTAssertEqual(code, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(err.contains("alpha - Alpha app\n"))
        XCTAssertTrue(err.contains("beta - Beta app\n"))
        XCTAssertTrue(err.contains("Re-run with -p <project>; if unsure, ask the user which project"))
    }

    func test_denied_exits_2_with_hint() {
        let broker = FakeBroker(.denied(reason: .notRegistered))
        let (code, _, err) = capture { o, e in
            CaseCommand(client: broker, cwd: dir, stdout: o, stderr: e).run(args: ["case", "run", "true"])
        }
        XCTAssertEqual(code, 2)
        XCTAssertTrue(err.contains("Register this app in Whytap"))
    }

    func test_run_sends_request_and_runs_with_masking() {
        let broker = FakeBroker(.runEnvironment(["TOK": secret]))
        let (code, out, _) = capture { o, e in
            CaseCommand(client: broker, cwd: dir, stdout: o, stderr: e)
                .run(args: ["case", "run", "-p", "alpha", "--only", "TOK,B", "echo $TOK; exit 5"])
        }
        XCTAssertEqual(code, 5)
        XCTAssertEqual(out, "[case:hidden]\n")
        XCTAssertEqual(broker.requests, [.resolveRun(project: "alpha", only: ["TOK", "B"],
                                                     command: "echo $TOK; exit 5", cwd: dir.path)])
    }

    func test_ls_prints_table_without_values() {
        let broker = FakeBroker(.keys([CaseKeyInfo(name: "API_KEY", description: "main", project: "alpha")]))
        let (code, out, _) = capture { o, e in
            CaseCommand(client: broker, cwd: dir, stdout: o, stderr: e).run(args: ["case", "ls", "-p", "alpha"])
        }
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.hasPrefix("NAME"))
        XCTAssertTrue(out.contains("API_KEY  alpha    main"))
        XCTAssertEqual(broker.requests, [.listKeys(project: "alpha")])
    }

    func test_no_client_exits_4() {
        let (code, _, err) = capture { o, e in
            CaseCommand(client: nil, unavailableMessage: "not in bundle", cwd: dir, stdout: o, stderr: e)
                .run(args: ["case", "ls"])
        }
        XCTAssertEqual(code, 4)
        XCTAssertTrue(err.contains("not in bundle"))
    }

    func test_usage_errors() {
        for args in [[], ["case"], ["case", "run"], ["case", "bogus"], ["case", "ls", "-x"]] {
            let (code, _, _) = capture { o, e in
                CaseCommand(client: FakeBroker(.keys([])), cwd: dir, stdout: o, stderr: e).run(args: args)
            }
            XCTAssertEqual(code, 64, "\(args)")
        }
    }

    // MARK: launching + socket client

    private final class Flaky: CaseBrokerCalling {
        var failures: Int
        init(failures: Int) { self.failures = failures }
        func send(_ r: CaseBrokerRequest) throws -> CaseBrokerResponse {
            if failures > 0 { failures -= 1; throw CaseBrokerClientError.unavailable }
            return .projects([])
        }
    }

    func test_launching_client_launches_once_then_succeeds() throws {
        var launches = 0
        let c = LaunchingBrokerClient(inner: Flaky(failures: 3), launch: { launches += 1 }, sleep: { _ in })
        XCTAssertEqual(try c.send(.listProjects), .projects([]))
        XCTAssertEqual(launches, 1)
    }

    func test_launching_client_gives_up_after_timeout() {
        var t = Date(timeIntervalSince1970: 0)
        let c = LaunchingBrokerClient(inner: Flaky(failures: 1000), launch: {}, timeout: 5,
                                      sleep: { t = t.addingTimeInterval($0) }, now: { t })
        XCTAssertThrowsError(try c.send(.listProjects)) {
            XCTAssertEqual($0 as? CaseBrokerClientError, .unavailable)
        }
    }

    func test_socket_client_roundtrip_and_missing_socket() throws {
        let sock = URL(fileURLWithPath: "/tmp/cc\(Int.random(in: 1000...9999)).sock")
        defer { unlink(sock.path) }
        XCTAssertThrowsError(try UnixSocketBrokerClient(socketURL: sock).send(.listProjects)) {
            XCTAssertEqual($0 as? CaseBrokerClientError, .unavailable)
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(sock.path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { r in for (i, b) in bytes.enumerated() { r[i] = b } }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        let received = expectation(description: "served")
        var seen = Data()
        DispatchQueue.global().async {
            let conn = accept(listener, nil, nil)
            var buf = [UInt8](repeating: 0, count: 4096)
            while !seen.contains(0x0A) {
                let n = read(conn, &buf, buf.count); if n <= 0 { break }
                seen.append(contentsOf: buf[0..<n])
            }
            let reply = try! CaseBrokerCodec.encodeLine(CaseBrokerResponse.projects(
                [CaseProjectInfo(name: "p", description: "d", keyCount: 2)]))
            _ = reply.withUnsafeBytes { write(conn, $0.baseAddress, reply.count) }
            close(conn); close(listener)
            received.fulfill()
        }
        let r = try UnixSocketBrokerClient(socketURL: sock, timeout: 5).send(.listKeys(project: "p"))
        wait(for: [received], timeout: 5)
        XCTAssertEqual(r, .projects([CaseProjectInfo(name: "p", description: "d", keyCount: 2)]))
        XCTAssertEqual(try CaseBrokerCodec.decodeLine(CaseBrokerRequest.self, from: seen), .listKeys(project: "p"))
    }

    func test_bundle_id_from_helper_location() throws {
        let app = dir.appendingPathComponent("Demo.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.demo"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertEqual(CaseHostBundle.bundleID(forExecutable: app.appendingPathComponent("Helpers/whytap")), "com.example.demo")
        XCTAssertNil(CaseHostBundle.bundleID(forExecutable: dir.appendingPathComponent("whytap")))
    }
}
