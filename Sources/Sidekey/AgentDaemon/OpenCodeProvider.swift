import Foundation
import Darwin

/// App-owned OpenCode runs use only OpenRouter, with the user's selected model
/// and Keychain key. Prompts go over stdin; neither prompts nor keys are CLI
/// arguments. stdout JSON is consumed in memory and stderr is never logged.
final class OpenCodeProvider: CLIProvider {
    let id: CLIProviderID = .opencode
    let displayName = "OpenCode"
    let installURL = URL(string: "https://opencode.ai/docs/")!
    typealias Runner = (URL, [String], URL, [String: String], String,
                        @escaping (String) -> Void, @escaping (Int32) -> Void) -> CodexProcessTerminating
    private let locate: () -> URL?
    private let readKey: () throws -> String?
    private let runStreaming: Runner
    private let versionProbe: (URL) -> ProcessResult?
    private let validateKey: (String) async -> ConnectOutcome
    private let sessionLock = NSLock()
    private var storedSessionID: String?
    private var currentRunID = UUID()

    var lastSessionID: String? { sessionLock.withLock { storedSessionID } }

    init(locate: @escaping () -> URL? = { OpenCodeBinaryLocator().locate() },
         readKey: @escaping () throws -> String? = { try OpenRouterLLMKeyStore().read() },
         versionProbe: @escaping (URL) -> ProcessResult? = { ClaudeCodeProvider.defaultRunOneShot(binary: $0, args: ["--version"]) },
         validateKey: @escaping (String) async -> ConnectOutcome = OpenCodeProvider.validateOpenRouterKey,
         runStreaming: @escaping Runner = OpenCodeProvider.defaultRunStreaming) {
        self.locate = locate
        self.readKey = readKey
        self.versionProbe = versionProbe
        self.validateKey = validateKey
        self.runStreaming = runStreaming
    }

    func discoverBinary() -> URL? { locate() }
    func respondToPermission(requestId: String, decision: PermissionDecision) {}

    /// Free local handshake; it never submits a paid model request.
    func probe() async -> ConnectOutcome {
        guard let binary = locate() else { return .notInstalled }
        guard let key = try? readKey(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notLoggedIn
        }
        let probe = versionProbe
        let result = await Task.detached { probe(binary) }.value
        guard let result, result.exitCode == 0,
              Self.supportsVersion(result.stdout) else {
            return .failed(code: "unsupported_version", message: "Install OpenCode 1.17.12 or newer from Settings → Agents.")
        }
        return await validateKey(key)
    }

    static func validateOpenRouterKey(_ key: String) async -> ConnectOutcome {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: return .connected(sessionID: nil)
            case 401, 403: return .notLoggedIn
            case 402: return .billing
            default: return .failed(code: "openrouter_unavailable", message: "OpenRouter is unavailable. Check your connection and retry.")
            }
        } catch {
            return .failed(code: "openrouter_network", message: "Couldn’t connect to OpenRouter. Check your connection and retry.")
        }
    }

    static func supportsVersion(_ raw: String) -> Bool {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".")
        guard parts.count >= 3, let major = Int(parts[0]), let minor = Int(parts[1]),
              let patch = Int(parts[2].prefix(while: \.isNumber)) else { return false }
        return major > 1 || (major == 1 && (minor > 17 || (minor == 17 && patch >= 12)))
    }

    func run(prompt: String, resumeSessionID: String?, options: AgentRunOptions) -> AsyncStream<AgentSSEEvent> {
        AsyncStream { continuation in
            func fail(_ code: String, _ message: String) {
                continuation.yield(.error(code: code, message: message, retryable: false))
                continuation.finish()
            }
            let runID = UUID()
            sessionLock.withLock { currentRunID = runID; storedSessionID = nil }
            guard let binary = locate() else { return fail("not_installed", "Install OpenCode in Settings → Agents.") }
            guard let key = try? readKey(), !key.isEmpty else {
                return fail("missing_key", "Save your OpenRouter key in Settings → Agents.")
            }
            guard let rawModel = options.model else {
                return fail("missing_model", "Choose an OpenRouter model in Settings → Agents.")
            }
            let model = OpenCodeEnvironment.normalizeModel(rawModel)
            guard !model.isEmpty, !model.contains(where: \.isWhitespace) else {
                return fail("missing_model", "Choose a valid OpenRouter model in Settings → Agents.")
            }
            let workingDir: URL
            let env: [String: String]
            do {
                if let project = options.projectContext {
                    workingDir = try AgentDaemonWorkingDirectory.ensure(projectID: project.projectID)
                } else {
                    workingDir = try options.workingDirectory ?? AgentDaemonWorkingDirectory.ensure()
                }
                env = try OpenCodeEnvironment.make(workingDirectory: workingDir, model: model,
                                                   key: key, allowActions: options.allowActions)
            } catch {
                return fail("workspace_error", "Couldn’t create the local OpenCode workspace.")
            }
            var args = ["run", "--format", "json", "--model", "openrouter/\(model)",
                        "--dir", workingDir.path, "--title", "Exodia"]
            if let session = resumeSessionID { args += ["--session", session] }
            if options.allowActions { args.append("--auto") }
            continuation.yield(.started(turnId: UUID().uuidString, requestId: "", sessionId: resumeSessionID ?? ""))
            var mapper = OpenCodeEventMapper()
            let handle = runStreaming(binary, args, workingDir, env, prompt, { [weak self] line in
                let events = mapper.map(line: line)
                if let self, let id = mapper.sessionID {
                    self.sessionLock.withLock {
                        if self.currentRunID == runID { self.storedSessionID = id }
                    }
                }
                events.forEach { continuation.yield($0) }
            }, { code in
                if code != 0 && !mapper.failed {
                    continuation.yield(.error(code: "opencode_exit", message: "OpenCode stopped before completing the request. Check your model and OpenRouter key, then retry.", retryable: true))
                } else if code == 0 && !mapper.failed {
                    if mapper.answer.isEmpty {
                        continuation.yield(.error(code: "empty_response", message: "OpenCode returned no answer. Try another model or repeat the request.", retryable: true))
                    } else {
                        continuation.yield(.done(sources: []))
                    }
                }
                continuation.finish()
            })
            continuation.onTermination = { _ in handle.terminate() }
        }
    }

    static func defaultRunStreaming(binary: URL, args: [String], workingDirectory: URL,
                                    environment: [String: String], prompt: String,
                                    onLine: @escaping (String) -> Void,
                                    onExit: @escaping (Int32) -> Void) -> CodexProcessTerminating {
        let handle = OpenCodeProcessHandle()
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = binary
            process.arguments = args
            process.currentDirectoryURL = workingDirectory
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try handle.start(process)
            } catch {
                onExit(-1)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
            }
            let watchdog = ProcessIdleWatchdog(softTimeout: 60, hardTimeout: 300,
                onSoft: {}, onHard: { handle.terminate() })
            watchdog.start()
            defer { watchdog.cancel() }
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                watchdog.kick()
                buffer.append(chunk)
                // Malformed or unbounded output must not exhaust app memory.
                if buffer.count > 4 * 1024 * 1024 { handle.terminate(); break }
                while let newline = buffer.firstIndex(of: 10) {
                    onLine(String(decoding: buffer[..<newline], as: UTF8.self))
                    buffer.removeSubrange(...newline)
                }
            }
            if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
            process.waitUntilExit()
            onExit(process.terminationStatus)
        }
        return handle
    }
}

private final class OpenCodeProcessHandle: CodexProcessTerminating {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    var processIdentifier: Int32? { lock.withLock { process?.isRunning == true ? process?.processIdentifier : nil } }

    func start(_ process: Process) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
            self.process = process
        }
    }

    func terminate() {
        let running: Process? = lock.withLock {
            cancelled = true
            guard let process, process.isRunning else { return nil }
            process.terminate()
            return process
        }
        guard let running else { return }
        let pid = running.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.process === running, running.isRunning,
                      running.processIdentifier == pid else { return }
                kill(pid, SIGKILL)
            }
        }
    }
}
