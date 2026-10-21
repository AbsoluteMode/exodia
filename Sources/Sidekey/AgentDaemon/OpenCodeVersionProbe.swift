import Foundation
import Darwin

/// Local version checks must neither load inherited credentials nor leave a
/// request stuck before its normal runtime watchdog has started.
enum OpenCodeVersionProbe {
    static func run(_ binary: URL, timeout: TimeInterval = 15) -> ProcessResult? {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "OPENCODE_DISABLE_AUTOUPDATE": "true", "OPENCODE_DISABLE_DEFAULT_PLUGINS": "true"]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = ProcessIdleWatchdog(softTimeout: timeout, hardTimeout: timeout + 0.5,
            onSoft: { if process.isRunning { process.terminate() } },
            onHard: { if process.isRunning { kill(process.processIdentifier, SIGKILL) } })
        watchdog.start()
        defer { watchdog.cancel() }
        var data = Data()
        var overflow = false
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            guard data.count + chunk.count <= 4096 else {
                overflow = true
                if process.isRunning { process.terminate() }
                break
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard !overflow, process.terminationStatus == 0 else { return nil }
        return ProcessResult(stdout: String(decoding: data, as: UTF8.self), stderr: "", exitCode: 0)
    }
}
