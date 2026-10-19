import Foundation
import Darwin

/// App-owned OpenCode runs use the provider of the `Agent` route (OpenRouter or
/// Anthropic), with that route's model and that provider's Keychain key; one
/// provider's key never stands in for the other's. Prompts go over stdin; neither prompts nor keys are CLI
/// arguments. stdout JSON is consumed in memory and stderr is never logged.
final class OpenCodeProvider: CLIProvider {
    let id: CLIProviderID = .opencode
    let displayName = "OpenCode"
    let installURL = URL(string: "https://opencode.ai/docs/")!
    typealias Runner = (URL, [String], URL, [String: String], String,
                        @escaping (String) -> Void, @escaping (Int32) -> Void) -> CodexProcessTerminating
    private let locate: () -> URL?
    private let readKey: (OpenCodeModelProvider) throws -> String?
    private let currentProvider: () async -> OpenCodeModelProvider
    private let runStreaming: Runner
    private let versionProbe: (URL) -> ProcessResult?
    private let validateKey: (OpenCodeModelProvider, String) async -> ConnectOutcome
    private let sessionLock = NSLock()
    private var storedSessionID: String?
    private var currentRunID = UUID()

    var lastSessionID: String? { sessionLock.withLock { storedSessionID } }

    init(locate: @escaping () -> URL? = { OpenCodeBinaryLocator().locate() },
         readKey: @escaping (OpenCodeModelProvider) throws -> String? = OpenCodeProvider.readKeychainKey,
         currentProvider: @escaping () async -> OpenCodeModelProvider = OpenCodeProvider.agentRouteProvider,
         versionProbe: @escaping (URL) -> ProcessResult? = { ClaudeCodeProvider.defaultRunOneShot(binary: $0, args: ["--version"]) },
         validateKey: @escaping (OpenCodeModelProvider, String) async -> ConnectOutcome = OpenCodeProvider.validate,
         runStreaming: @escaping Runner = OpenCodeProvider.defaultRunStreaming) {
        self.locate = locate
        self.readKey = readKey
        self.currentProvider = currentProvider
        self.versionProbe = versionProbe
        self.validateKey = validateKey
        self.runStreaming = runStreaming
    }

    func discoverBinary() -> URL? { locate() }
    func respondToPermission(requestId: String, decision: PermissionDecision) {}

    /// The provider's Keychain key: OpenRouter's from its LLM key store,
    /// Anthropic's from its own item.
    static func readKeychainKey(_ provider: OpenCodeModelProvider) throws -> String? {
        switch provider {
        case .openRouter: return try OpenRouterLLMKeyStore().read()
        case .anthropic: return ProviderKeyStore().read(account: ProviderAccount.anthropicKeychainAccount)
        }
    }

    /// The provider of the current `Agent` route; OpenRouter when none is set,
    /// as before Anthropic existed.
    static func agentRouteProvider() async -> OpenCodeModelProvider {
        await MainActor.run { AgentSettingsStore.shared.selectedOpenCodeProvider ?? .openRouter }
    }

    static func validate(_ provider: OpenCodeModelProvider, key: String) async -> ConnectOutcome {
        switch provider {
        case .openRouter: return await validateOpenRouterKey(key)
        case .anthropic: return await validateAnthropicKey(key)
        }
    }

    /// Anthropic's free models list, through the API & Models key checker.
    static func validateAnthropicKey(_ key: String) async -> ConnectOutcome {
        switch await ProviderKeyChecker().check(.anthropic, apiKey: key, server: nil, allowPaidProbe: false) {
        case .valid, .limited: return .connected(sessionID: nil)
        case .rejected(.invalidKey): return .notLoggedIn
        case .rejected(.outOfCredit): return .billing
        case .unreachable:
            return .failed(code: "anthropic_unavailable", message: "Couldn’t reach Anthropic. Check your connection and retry.")
        }
    }

    /// Free local handshake; it never submits a paid model request.
    func probe() async -> ConnectOutcome {
        guard let binary = locate() else { return .notInstalled }
        let provider = await currentProvider()
        guard let key = try? readKey(provider), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notLoggedIn
        }
        let probe = versionProbe
        let result = await Task.detached { probe(binary) }.value
        guard let result, result.exitCode == 0,
              Self.supportsVersion(result.stdout) else {
            return .failed(code: "unsupported_version", message: "Install OpenCode 1.17.12 or newer from Settings → Agents.")
        }
        return await validateKey(provider, key)
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
            let provider = options.openCodeProvider
            guard let key = try? readKey(provider), !key.isEmpty else {
                return fail("missing_key", "Add your \(provider.displayName) key in Settings → API & Models.")
            }
            guard let rawModel = options.model else {
                return fail("missing_model", "Choose a model in API & Models.")
            }
            let model = OpenCodeEnvironment.normalizeModel(rawModel)
            guard !model.isEmpty, !model.contains(where: \.isWhitespace) else {
                return fail("missing_model", "Choose a model in API & Models.")
            }
            let workingDir: URL
            let env: [String: String]
            do {
                workingDir = try options.workingDirectory ?? AgentDaemonWorkingDirectory.ensure()
                env = try OpenCodeEnvironment.make(workingDirectory: workingDir, model: model, provider: provider,
                                                   key: key, allowActions: options.allowActions,
                                                   modelSpec: options.openCodeModelSpec)
            } catch {
                return fail("workspace_error", "Couldn’t create the local OpenCode workspace.")
            }
            var args = ["run", "--format", "json", "--model", "\(provider.openCodeID)/\(model)",
                        "--dir", workingDir.path, "--title", "Exodia"]
            if let session = resumeSessionID { args += ["--session", session] }
            if options.allowActions { args.append("--auto") }
            continuation.yield(.started(turnId: UUID().uuidString, requestId: "", sessionId: resumeSessionID ?? ""))
            var mapper = OpenCodeEventMapper(provider: provider)
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
                    continuation.yield(.error(code: "opencode_exit", message: "OpenCode stopped before completing the request. Check your model and \(provider.displayName) key, then retry.", retryable: true))
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
