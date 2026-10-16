import Foundation

enum MonitorProcessError: Error, Equatable { case failed, timedOut, outputLimit }

/// Fixed executable/argv only, with bounded memory, time and cancellation.
/// stderr deliberately never reaches app logs or the dashboard (SSH/CLI
/// errors can contain private hosts and authentication details).
struct MonitorProcessRunner {
    func run(executable: URL, arguments: [String], environment: [String: String]? = nil,
             timeout: Double = 12) async throws -> Data {
        let operation = MonitorProcessOperation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.start(executable: executable, arguments: arguments,
                                environment: environment, timeout: timeout,
                                continuation: continuation)
            }
        }, onCancel: { operation.cancel() })
    }

    static func executable(named name: String) -> URL? {
        let fm = FileManager.default
        let directories = [fm.homeDirectoryForCurrentUser.appendingPathComponent("bin").path,
                           "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }
}

private final class MonitorProcessOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<Data, Error>?
    private var output = Data()
    private var failure: Error?
    private var cancelled = false
    private var timer: DispatchWorkItem?
    private let maxOutputBytes = 256_000

    func start(executable: URL, arguments: [String], environment: [String: String]?,
               timeout: Double, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        self.process = process
        self.continuation = continuation
        let readerFinished = DispatchGroup()
        readerFinished.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { readerFinished.leave(); try? pipe.fileHandleForReading.close() }
            while let data = try? pipe.fileHandleForReading.read(upToCount: 16_384), !data.isEmpty {
                self?.append(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            readerFinished.wait()
            self?.finish(status: process.terminationStatus)
        }
        do {
            try process.run()
            let timeoutWork = DispatchWorkItem { [weak self] in self?.stop(with: MonitorProcessError.timedOut) }
            timer = timeoutWork
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        } catch {
            try? pipe.fileHandleForWriting.close()
            self.continuation = nil
            self.process = nil
            lock.unlock()
            continuation.resume(throwing: MonitorProcessError.failed)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        stop(with: CancellationError())
    }

    private func append(_ data: Data) {
        lock.lock()
        let exceedsLimit = output.count + data.count > maxOutputBytes
        if !exceedsLimit { output.append(data) }
        lock.unlock()
        if exceedsLimit { stop(with: MonitorProcessError.outputLimit) }
    }

    private func stop(with error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        let running = process
        lock.unlock()
        if let running, running.isRunning {
            running.terminate()
            // A stalled child must not keep a refresh/cancellation alive.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if running.isRunning { kill(running.processIdentifier, SIGKILL) }
            }
        }
    }

    private func finish(status: Int32) {
        lock.lock()
        timer?.cancel()
        let completion = continuation
        continuation = nil
        process = nil
        let result = output
        let error = failure ?? (status == 0 ? nil : MonitorProcessError.failed)
        lock.unlock()
        if let error { completion?.resume(throwing: error) }
        else { completion?.resume(returning: result) }
    }
}
