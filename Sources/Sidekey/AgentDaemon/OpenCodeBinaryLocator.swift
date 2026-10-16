import Foundation

struct OpenCodeBinaryLocator {
    var fileManager: FileManager = .default
    var loginShellWhich: (String) -> String? = { LoginShellWhich.resolve($0) }

    static var managedBinaryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("whytap/tools/opencode", isDirectory: false)
    }

    func locate() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [Self.managedBinaryURL.path, "\(home)/.opencode/bin/opencode",
            "\(home)/.npm-global/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let path = loginShellWhich("opencode"), path.hasPrefix("/"),
              fileManager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
