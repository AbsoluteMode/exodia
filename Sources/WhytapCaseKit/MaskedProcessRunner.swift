import Foundation

/// Runs `/bin/sh -c <command>` with secret values in its environment only
/// (never argv) and passes stdout and stderr through the masker.
public struct MaskedProcessRunner {
    public static func run(
        command: String,
        environment: [String: String],
        cwd: URL,
        masker: CaseOutputMasker,
        stdout: FileHandle = .standardOutput,
        stderr: FileHandle = .standardError
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = cwd
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        let group = DispatchGroup()
        func pump(_ pipe: Pipe, _ sink: FileHandle, _ m: CaseOutputMasker) {
            group.enter()
            DispatchQueue.global().async {
                let reader = pipe.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    let safe = m.feed(chunk)
                    if !safe.isEmpty { try? sink.write(contentsOf: safe) }
                }
                let rest = m.finish()
                if !rest.isEmpty { try? sink.write(contentsOf: rest) }
                group.leave()
            }
        }
        pump(outPipe, stdout, masker)
        pump(errPipe, stderr, masker.makeFresh())
        process.waitUntilExit()
        group.wait()
        return process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus : process.terminationStatus
    }
}
