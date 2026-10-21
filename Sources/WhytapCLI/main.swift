import Foundation
import WhytapCaseKit

// `whytap case ls | run`. Locates the enclosing app (Ruling 3) at runtime.
let executable = URL(fileURLWithPath: CommandLine.arguments[0].contains("/")
    ? CommandLine.arguments[0]
    : (Bundle.main.executablePath ?? CommandLine.arguments[0]))
let hostExecutable = Bundle.main.executableURL ?? executable

var client: CaseBrokerCalling?
let message = "Whytap is not available: this helper is not inside the Whytap app bundle."
if let bundleID = CaseHostBundle.bundleID(forExecutable: hostExecutable) {
    let socket = CaseBrokerPaths.socketURL(bundleID: bundleID)
    client = LaunchingBrokerClient(
        inner: UnixSocketBrokerClient(socketURL: socket),
        launch: {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-b", bundleID]
            try? open.run()
            open.waitUntilExit()
        })
}
let resolvedPath = hostExecutable.resolvingSymlinksInPath().path
if CommandLine.arguments.dropFirst().first == "app" {
    exit(AppControlCommand(client: client).run(args: Array(CommandLine.arguments.dropFirst(2))))
}
exit(CaseCommand(client: client, executablePath: resolvedPath, unavailableMessage: message)
    .run(args: Array(CommandLine.arguments.dropFirst())))
