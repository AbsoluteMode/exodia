import Darwin
import Foundation

/// Child owns a process group so disabling a source / quitting stops its helpers too.
/// No shell interpolation: the manifest is an argv array, passed directly to exec.
/// The group leader is `parentWatchGuardScript`, so the group also ends when the
/// app is killed or crashes.
final class NotifyProcess: @unchecked Sendable {
    /// Parent-death guard and process-group leader. `/usr/bin/perl -e <this> --
    /// <command…>` forks the script (stdin on /dev/null, same group) and blocks
    /// reading its own stdin, the write end of which only this app holds. The
    /// kernel closes that end whenever the app dies, including SIGKILL and crashes,
    /// so EOF makes the guard TERM the whole group, wait up to 1 s for the script,
    /// then KILL the group (itself included), like stop(). When the script exits
    /// on its own the guard exits with the script's status (128+signal for a
    /// signal), so retry and backoff see the same result as before.
    /// WHY: .project-docs/decisions/2026-10-19-notify-parent-death-guard.md
    static let parentWatchGuardScript = """
        use POSIX ();
        my $pid;
        sub reap {
          return unless $pid && waitpid($pid, POSIX::WNOHANG()) == $pid;
          my $s = $?;
          POSIX::_exit(($s & 127) ? 128 + ($s & 127) : ($s >> 8));
        }
        $SIG{CHLD} = sub { reap() };
        $pid = fork();
        POSIX::_exit(126) unless defined $pid;
        if ($pid == 0) {
          $SIG{CHLD} = 'DEFAULT';
          open(STDIN, '<', '/dev/null');
          exec { $ARGV[0] } @ARGV or POSIX::_exit(127);
        }
        reap();
        my $buf;
        while (1) {
          my $n = sysread(STDIN, $buf, 4096);
          last if defined $n && $n == 0;
          next if defined $n;
          last unless $!{EINTR};
        }
        $SIG{CHLD} = 'DEFAULT';
        $SIG{TERM} = 'IGNORE';
        my $group = getpgrp();
        kill('-TERM', $group);
        for (1 .. 20) {
          last if waitpid($pid, POSIX::WNOHANG()) != 0;
          select(undef, undef, undef, 0.05);
        }
        kill('-KILL', $group);
        POSIX::_exit(0);
        """

    let pid: pid_t
    private let output: FileHandle
    /// Write end of the guard's stdin. Closing it (or the app dying) ends the group.
    private let lifeline: Int32
    private var lifelineOpen = true
    private let queue = DispatchQueue(label: "com.rootwise.sidekey.notify.output")
    private let lock = NSLock()
    private var exited = false
    private var stopping = false
    private let finished = DispatchGroup()

    init(command: [String], environment: [String: String],
         onData: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) throws {
        guard let executable = command.first else { throw NotifyError.invalidConfiguration }
        // The guard always starts; check the script itself so a missing executable
        // still fails here instead of becoming a retried exit status.
        var info = stat()
        guard stat(executable, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        guard info.st_mode & S_IFMT == S_IFREG, access(executable, X_OK) == 0 else { throw POSIXError(.EACCES) }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        var lifelineDescriptors: [Int32] = [0, 0]
        guard pipe(&lifelineDescriptors) == 0 else { close(descriptors[0]); close(descriptors[1]); throw POSIXError(.EIO) }
        // No other child of the app may inherit the write end, or EOF would never come.
        _ = fcntl(lifelineDescriptors[1], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        // An empty signal mask: a spawning thread (GCD/Swift concurrency) may block
        // SIGCHLD, which the guard needs to see the script exit.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignalsBlocked = sigset_t()
        sigemptyset(&noSignalsBlocked)
        posix_spawnattr_setsigmask(&attributes, &noSignalsBlocked)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, lifelineDescriptors[0], STDIN_FILENO)
        // Error output can contain credentials. Discard it; UI reports only exit status.
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var argv = (["/usr/bin/perl", "-e", Self.parentWatchGuardScript, "--"] + command).map { strdup($0) } + [nil]
        var env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, "/usr/bin/perl", &actions, &attributes, &argv, &env)
        close(descriptors[1]); close(lifelineDescriptors[0])
        guard result == 0 else {
            close(descriptors[0]); close(lifelineDescriptors[1])
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        pid = child
        lifeline = lifelineDescriptors[1]
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
            closeLifeline()
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
    /// What the kernel does when the app dies; exposed for tests.
    func closeLifeline() {
        lock.lock(); defer { lock.unlock() }
        guard lifelineOpen else { return }
        lifelineOpen = false
        close(lifeline)
    }
    func waitUntilStopped() { _ = finished.wait(timeout: .now() + 1.5) }
}
