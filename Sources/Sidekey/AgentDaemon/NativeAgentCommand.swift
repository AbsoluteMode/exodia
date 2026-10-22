import Darwin
import Foundation

/// A separate process group makes cancellation cover the shell and descendants.
/// Only this gated child is registered with Case, preserving existing approvals.
final class NativeAgentCommand: @unchecked Sendable {
    private let lock = NSLock()
    private let output = Pipe()
    private let gate = Pipe()
    private var pid: pid_t = 0
    private var data = Data()
    private var continuation: CheckedContinuation<String, Never>?
    private var finished = false
    private var interrupted = false
    private var truncated = false
    private var outputEnded = false
    private var exitSuffix: String?

    func run(command: String, directory: URL, helper: URL?, timeout: Duration = .seconds(30)) async -> String {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                if Task.isCancelled { finish("Command cancelled."); return }
                var environment = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"].contains($0.key) }
                environment["PATH"] = ([helper?.deletingLastPathComponent().path].compactMap { $0 }
                    + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
                output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let chunk = handle.availableData
                    guard let self else { return }
                    if chunk.isEmpty {
                        let suffix = self.lock.withLock { self.outputEnded = true; return self.exitSuffix }
                        handle.readabilityHandler = nil
                        if let suffix { self.finish(suffix) }
                        return
                    }
                    self.lock.withLock {
                        let room = max(0, 32_000 - self.data.count)
                        self.data.append(chunk.prefix(room))
                        self.truncated = self.truncated || chunk.count > room
                    }
                }
                do {
                    let child = try spawn(command: command, directory: directory, environment: environment)
                    lock.withLock { pid = child }
                    CaseBuiltInAgentProcesses.shared.insert(child)
                    if lock.withLock({ interrupted }) { stop() }
                    else { try? gate.fileHandleForWriting.write(contentsOf: Data("start\n".utf8)) }
                    try? gate.fileHandleForWriting.close()
                    try? gate.fileHandleForReading.close()
                    try? output.fileHandleForWriting.close()
                    DispatchQueue.global().async { [self] in
                        // Observe exit without reaping: retaining the leader PID
                        // prevents its group ID being reused before descendant cleanup.
                        var info = siginfo_t()
                        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
                        kill(-child, SIGKILL)
                        var status: Int32 = 0
                        while waitpid(child, &status, 0) == -1 && errno == EINTR {}
                        lock.withLock { pid = 0 }
                        CaseBuiltInAgentProcesses.shared.remove(child)
                        let suffix = lock.withLock {
                            let text = interrupted ? "\n[Command stopped]" : "\n[Exit \((status >> 8) & 0xff)]"
                            exitSuffix = text
                            return outputEnded ? text : nil
                        }
                        if let suffix { finish(suffix) }
                    }
                    Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        self?.stop()
                    }
                } catch { finish("Couldn’t start this command.") }
            }
        } onCancel: { self.stop() }
    }

    private func spawn(command: String, directory: URL, environment: [String: String]) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, gate.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        guard posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0 else { throw CocoaError(.fileNoSuchFile) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        for handle in [gate.fileHandleForReading, gate.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        let arguments = ["/bin/sh", "-c", "read -r _whytap_start\n" + command].map { $0.withCString { strdup($0) } } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { arguments.forEach { free($0) }; variables.forEach { free($0) } }
        var child: pid_t = 0
        let result = arguments.withUnsafeBufferPointer { argv in
            variables.withUnsafeBufferPointer { envp in
                posix_spawn(&child, "/bin/sh", &actions, &attributes,
                            UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: envp.baseAddress!))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return child
    }

    private func stop() {
        let child: pid_t? = lock.withLock {
            guard !finished else { return nil }
            interrupted = true
            return pid > 0 ? pid : nil
        }
        guard let child else { return }
        kill(-child, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            // The wait handler owns reaping; do not signal after it has finished.
            guard self.lock.withLock({ !self.finished && self.pid == child }) else { return }
            kill(-child, SIGKILL)
        }
    }

    private func finish(_ suffix: String) {
        let result: (CheckedContinuation<String, Never>, String, pid_t)? = lock.withLock {
            guard !finished, let continuation else { return nil }
            finished = true; self.continuation = nil
            return (continuation, String(decoding: data, as: UTF8.self) + (truncated ? "\n[Output shortened]" : "") + suffix, pid)
        }
        guard let result else { return }
        output.fileHandleForReading.readabilityHandler = nil
        if result.2 > 0 { CaseBuiltInAgentProcesses.shared.remove(result.2) }
        result.0.resume(returning: result.1)
    }
}
