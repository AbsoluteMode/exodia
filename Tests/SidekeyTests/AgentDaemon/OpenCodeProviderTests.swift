import XCTest
@testable import Sidekey

final class OpenCodeProviderTests: XCTestCase {
    func testCancellationKillsChildThatIgnoresSIGTERM() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = expectation(description: "child ready")
        let exited = expectation(description: "child reaped")
        let handle = OpenCodeProvider.defaultRunStreaming(binary: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "trap '' TERM; printf 'ready\\n'; while :; do :; done"],
            workingDirectory: directory, environment: ["PATH": "/usr/bin:/bin"], prompt: "",
            onLine: { if $0 == "ready" { ready.fulfill() } },
            onExit: { status in XCTAssertNotEqual(status, 0); exited.fulfill() })
        defer { handle.terminate() }
        await fulfillment(of: [ready], timeout: 3)
        handle.terminate()
        await fulfillment(of: [exited], timeout: 3)
        XCTAssertNil(handle.processIdentifier)
    }

    func testLatePreviousRunCannotReplaceCurrentSessionID() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var lines: [(String) -> Void] = []
        var exits: [(Int32) -> Void] = []
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") }, readKey: { "test-key" },
            runStreaming: { _, _, _, _, _, onLine, onExit in
                lines.append(onLine); exits.append(onExit)
                return CodexProcessHandle.noop
            })
        let first = provider.run(prompt: "first", resumeSessionID: nil,
            options: AgentRunOptions(model: "vendor/model", workingDirectory: directory))
        let second = provider.run(prompt: "second", resumeSessionID: nil,
            options: AgentRunOptions(model: "vendor/model", workingDirectory: directory))
        lines[1](#"{"type":"text","sessionID":"second-session","part":{"text":"Second answer"}}"#)
        lines[0](#"{"type":"text","sessionID":"late-first-session","part":{"text":"Old answer"}}"#)
        XCTAssertEqual(provider.lastSessionID, "second-session")
        exits[0](0); exits[1](0)
        for await _ in first {}
        for await _ in second {}
        XCTAssertEqual(provider.lastSessionID, "second-session")
    }

    func testConnectChecksVersionAndKeyWithoutModelRequest() async {
        var validations = 0
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") },
            readKey: { "test-key" },
            versionProbe: { _ in ProcessResult(stdout: "1.17.12\n", stderr: "", exitCode: 0) },
            validateKey: { _ in validations += 1; return .connected(sessionID: nil) })
        let result = await provider.probe()
        XCTAssertEqual(result, .connected(sessionID: nil))
        XCTAssertEqual(validations, 1)
    }

    func testOldCLIIsRejectedBeforeContactingProvider() async {
        var validations = 0
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") },
            readKey: { "test-key" },
            versionProbe: { _ in ProcessResult(stdout: "1.16.0", stderr: "", exitCode: 0) },
            validateKey: { _ in validations += 1; return .connected(sessionID: nil) })
        guard case .failed(let code, _) = await provider.probe() else { return XCTFail("Expected update requirement") }
        XCTAssertEqual(code, "unsupported_version")
        XCTAssertEqual(validations, 0)
    }

    func testRunKeepsPromptAndKeyOutOfArgumentsAndWaitsForProcessExit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var capturedArguments: [String] = []
        var capturedInput = ""
        var capturedEnvironment: [String: String] = [:]
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") }, readKey: { "test-key" },
            runStreaming: { _, args, _, env, input, onLine, onExit in
                capturedArguments = args; capturedInput = input; capturedEnvironment = env
                onLine(#"{"type":"step_start","sessionID":"ses_123"}"#)
                onLine(#"{"type":"step_finish","part":{"reason":"tool-calls"}}"#)
                onLine(#"{"type":"text","sessionID":"ses_123","part":{"id":"p1","text":"Answer"}}"#)
                onExit(0)
                return CodexProcessHandle.noop
            })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "private question", resumeSessionID: "ses_previous",
            options: AgentRunOptions(model: "google/example", workingDirectory: directory)) { events.append(event) }
        XCTAssertEqual(capturedInput, "private question")
        XCTAssertFalse(capturedArguments.contains("private question"))
        XCTAssertFalse(capturedArguments.contains("test-key"))
        XCTAssertTrue(capturedArguments.contains("openrouter/google/example"))
        XCTAssertTrue(capturedArguments.contains("ses_previous"))
        XCTAssertEqual(capturedEnvironment["OPENROUTER_API_KEY"], "test-key")
        XCTAssertEqual(provider.lastSessionID, "ses_123")
        XCTAssertEqual(events.filter { if case .done = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(events.contains(.finalAnswer(text: "Answer")))
    }

    func testMissingModelDoesNotStartProcess() async {
        var started = false
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") }, readKey: { "test-key" },
            runStreaming: { _, _, _, _, _, _, _ in started = true; return CodexProcessHandle.noop })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "hello", resumeSessionID: nil, options: AgentRunOptions()) { events.append(event) }
        XCTAssertFalse(started)
        guard case .error(let code, _, _) = events.first else { return XCTFail("Expected missing model error") }
        XCTAssertEqual(code, "missing_model")
    }

    func testMapperDoesNotFinishOnToolStepOrRepeatParts() {
        var mapper = OpenCodeEventMapper()
        XCTAssertTrue(mapper.map(line: #"{"type":"step_finish","part":{"reason":"tool-calls"}}"#).isEmpty)
        let text = #"{"type":"text","sessionID":"ses_a","part":{"id":"part_1","text":"First"}}"#
        XCTAssertFalse(mapper.map(line: text).isEmpty)
        XCTAssertTrue(mapper.map(line: text).isEmpty)
        _ = mapper.map(line: #"{"type":"text","part":{"id":"part_2","text":"Second"}}"#)
        XCTAssertEqual(mapper.answer, "First\n\nSecond")
        XCTAssertEqual(mapper.sessionID, "ses_a")
    }

    func testMapperNeverEchoesSensitiveErrorPayload() {
        var mapper = OpenCodeEventMapper()
        let events = mapper.map(line: #"{"type":"error","error":{"name":"ProviderAuthError","data":{"message":"secret-key private prompt"}}}"#)
        XCTAssertTrue(mapper.failed)
        guard case .error(let code, let message, _) = events.first else { return XCTFail("Expected error") }
        XCTAssertEqual(code, "opencode_auth")
        XCTAssertFalse(message.contains("secret-key"))
        XCTAssertFalse(message.contains("private prompt"))
    }

    func testEnvironmentIsProjectScopedAndDoesNotSerializeKey() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = try OpenCodeEnvironment.make(workingDirectory: directory, model: "vendor/model", key: "test-key",
            allowActions: true, inherited: ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "unrelated", "OPENCODE_CONFIG": "/private/config"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["OPENCODE_CONFIG"])
        XCTAssertEqual(env["OPENCODE_DISABLE_CLAUDE_CODE"], "true")
        for name in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"] {
            XCTAssertTrue(env[name]?.hasPrefix(directory.path + "/") == true)
        }
        let config = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"])
        XCTAssertFalse(config.contains("test-key"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        XCTAssertEqual(json["share"] as? String, "disabled")
        XCTAssertEqual(json["enabled_providers"] as? [String], ["openrouter"])
        XCTAssertEqual((json["permission"] as? [String: String])?["*"], "allow")
    }

    func testReadOnlyIsOptionalAndNeverTheDefault() throws {
        XCTAssertTrue(AgentRunOptions().allowActions)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = try OpenCodeEnvironment.make(workingDirectory: directory, model: "vendor/model", key: nil, allowActions: false)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(env["OPENCODE_CONFIG_CONTENT"]!.utf8)) as? [String: Any])
        XCTAssertEqual((json["permission"] as? [String: String])?["*"], "deny")
        XCTAssertEqual((json["permission"] as? [String: String])?["read"], "allow")
    }

    func testAutoRouterModelKeepsItsProviderNamespace() {
        XCTAssertEqual(OpenCodeEnvironment.normalizeModel("openrouter/auto"), "openrouter/auto")
        XCTAssertEqual(OpenCodeEnvironment.normalizeModel("openrouter/google/example"), "google/example")
    }

    func testProjectDirectoryIsSiblingOfNeutralMemory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let neutral = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: root)
        let first = try AgentDaemonWorkingDirectory.ensure(projectID: UUID(), appSupportDirectory: root)
        let second = try AgentDaemonWorkingDirectory.ensure(projectID: UUID(), appSupportDirectory: root)
        XCTAssertFalse(first.path.hasPrefix(neutral.path + "/"))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("AGENTS.md").path))
    }

    func testInstallerRequiresExactOfficialSHA256() {
        let data = Data("hello".utf8)
        XCTAssertTrue(OpenCodeInstaller.verify(data, digest: "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
        XCTAssertFalse(OpenCodeInstaller.verify(data, digest: nil))
        XCTAssertFalse(OpenCodeInstaller.verify(Data("changed".utf8), digest: "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
        XCTAssertEqual(OpenCodeInstaller.assetName(appleSilicon: false), "opencode-darwin-x64-baseline.zip")
    }

    func testProjectPromptLabelsExcerptsAsUntrustedAndRequiresCitations() {
        let context = AgentProjectContext(projectID: UUID(), displayName: "Example", sourceExcerpts: "schema.sql:12 status CHECK ('new','done')")
        XCTAssertTrue(context.promptEvidence.contains("untrusted project evidence"))
        XCTAssertTrue(context.promptEvidence.contains("schema.sql:12"))
        XCTAssertTrue(context.promptEvidence.contains("Observed database values do not prove"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whytap-opencode-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
