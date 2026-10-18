import Foundation
import CryptoKit
import Darwin

enum OpenCodeInstallError: Error, LocalizedError {
    case invalidRelease, invalidDownload, checksum, extraction
    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "Couldn’t find an official OpenCode release for this Mac."
        case .invalidDownload: return "Couldn’t download OpenCode. Check your connection and retry."
        case .checksum: return "OpenCode checksum verification failed. Retry the download."
        case .extraction: return "Couldn’t install OpenCode. The previous installation is unchanged."
        }
    }
}

struct OpenCodeInstaller {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let digest: String?
    }
    struct Release: Decodable { let tag_name: String; let assets: [Asset] }
    var session: URLSession = .shared
    var destination: URL = OpenCodeBinaryLocator.managedBinaryURL

    static func assetName(appleSilicon: Bool) -> String {
        appleSilicon ? "opencode-darwin-arm64.zip" : "opencode-darwin-x64-baseline.zip"
    }

    static func verify(_ data: Data, digest: String?) -> Bool {
        guard let digest, digest.hasPrefix("sha256:") else { return false }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest.lowercased() == "sha256:\(hash)"
    }

    /// Explicit user action only. Never executes a downloaded installer script
    /// and never modifies Homebrew/npm/global user installations.
    func install() async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/anomalyco/opencode/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (metadata, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: metadata),
              let asset = release.assets.first(where: { $0.name == Self.assetName(appleSilicon: HostArchitecture.isAppleSilicon) }),
              let url = URL(string: asset.browser_download_url), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/anomalyco/opencode/releases/download/") else { throw OpenCodeInstallError.invalidRelease }
        let (archive, downloadResponse) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200,
              let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 500 * 1024 * 1024 else { throw OpenCodeInstallError.invalidDownload }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard Self.verify(data, digest: asset.digest) else { throw OpenCodeInstallError.checksum }
        try Task.checkCancellation()
        let target = destination
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            // Extract one exact entry to stdout; zip paths can never escape into
            // another user directory and no installation script runs.
            process.arguments = ["-p", archive.path, "opencode"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let binary = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !binary.isEmpty else { throw OpenCodeInstallError.extraction }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staged = target.deletingLastPathComponent().appendingPathComponent(".opencode-\(UUID())")
            defer { try? FileManager.default.removeItem(at: staged) }
            try binary.write(to: staged, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            // chmod happens before the atomic rename, so failure cannot replace
            // a working executable with an incomplete or non-executable file.
            guard rename(staged.path, target.path) == 0 else { throw OpenCodeInstallError.extraction }
        }.value
        return release.tag_name
    }
}
