import Darwin
import Foundation

/// Child owns a process group so disabling a source / quitting stops its helpers too.
/// No shell interpolation: the manifest is an argv array, passed directly to exec.
final class NotifyProcess: @unchecked Sendable {
    let pid: pid_t
    private let output: FileHandle
    private let queue = DispatchQueue(label: "com.rootwise.sidekey.notify.output")
    private let lock = NSLock()
    private var exited = false
    private var stopping = false
    private let finished = DispatchGroup()

    init(command: [String], environment: [String: String],
         onData: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) throws {
        guard !command.isEmpty else { throw NotifyError.invalidConfiguration }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        // Error output can contain credentials. Discard it; UI reports only exit status.
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var argv = command.map { strdup($0) } + [nil]
        var env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, command[0], &actions, &attributes, &argv, &env)
        close(descriptors[1])
        guard result == 0 else { close(descriptors[0]); throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        pid = child
        output = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        // Reading until EOF drains the final line BEFORE reporting process exit.
        // A bounded read avoids FileHandle.availableData retaining unbounded output.
        queue.async { [self] in
            var window = Date(), bytes = 0
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let data = Data(buffer.prefix(count))
                if Date().timeIntervalSince(window) >= 1 { window = Date(); bytes = 0 }
                bytes += data.count
                if bytes > 1_048_576 { stop(); break }
                onData(data)
            }
            try? output.close()
        }
        finished.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            // Keep the group leader as a zombie until helper cleanup completes:
            // its reserved PID prevents a delayed kill from hitting a reused group.
            var info = siginfo_t()
            while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            kill(-child, SIGTERM)
            usleep(1_000_000)
            lock.lock()
            kill(-child, SIGKILL)
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            exited = true
            lock.unlock()
            finished.leave()
            queue.async { onExit(status) }
        }
    }
    func stop() {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        stopping = true
        let alive = !exited
        if alive { kill(-pid, SIGTERM) }
        lock.unlock()
        if alive {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock()
                if !exited { kill(-pid, SIGKILL) }
                lock.unlock()
            }
        }
    }
    func waitUntilStopped() { _ = finished.wait(timeout: .now() + 1.5) }
}
