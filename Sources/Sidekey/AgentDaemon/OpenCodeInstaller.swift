import Foundation
import CryptoKit
import Darwin

enum OpenCodeInstallError: Error, LocalizedError {
    case invalidRelease, invalidDownload, checksum, extraction
    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "Couldn’t find an official stable OpenCode 2 release for this Mac."
        case .invalidDownload: return "Couldn’t download OpenCode. Check your connection and retry."
        case .checksum: return "OpenCode checksum verification failed. Retry the download."
        case .extraction: return "Couldn’t install OpenCode. The previous installation is unchanged."
        }
    }
}

// WHY: .project-docs/decisions/2026-10-21-opencode-v2.md
// V2's official installer distributes native packages through npm, while the
// GitHub releases/latest endpoint still supplies V1. Read package metadata and
// verify its SHA-512 integrity without running npm or any installation script.
struct OpenCodeInstaller {
    struct Distribution: Decodable { let tarball: String; let integrity: String? }
    struct Package: Decodable { let name: String; let version: String; let dist: Distribution }
    var session: URLSession = .shared
    var destination: URL = OpenCodeBinaryLocator.managedBinaryURL

    static func packageName(appleSilicon: Bool) -> String {
        appleSilicon ? "@opencode/cli-darwin-arm64" : "@opencode/cli-darwin-x64-baseline"
    }

    static func verify(_ data: Data, integrity: String?) -> Bool {
        guard let integrity, integrity.hasPrefix("sha512-"),
              let expected = Data(base64Encoded: String(integrity.dropFirst(7))),
              expected.count == SHA512.Digest.byteCount else { return false }
        return Data(SHA512.hash(data: data)) == expected
    }

    static func archiveURL(package: Package, expectedName: String, version: String) -> URL? {
        guard package.name == expectedName, package.version == version,
              OpenCodeProvider.versionComponents(version)?.first == 2,
              OpenCodeProvider.versionComponents(version)?.map(String.init).joined(separator: ".") == version,
              OpenCodeProvider.supportsVersion(version) else { return nil }
        let filename = String(expectedName.dropFirst("@opencode/".count))
        let expected = "https://registry.npmjs.org/\(expectedName)/-/\(filename)-\(version).tgz"
        guard package.dist.tarball == expected else { return nil }
        return URL(string: expected)
    }

    private func metadata(at url: URL) async throws -> Package {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let package = try? JSONDecoder().decode(Package.self, from: data) else {
            throw OpenCodeInstallError.invalidRelease
        }
        return package
    }

    /// Explicit user action only. No global installation or shell configuration
    /// is changed, and a failed download/extraction keeps the previous binary.
    func install() async throws -> String {
        let release = try await metadata(at: URL(string: "https://registry.npmjs.org/@opencode%2fcli/latest")!)
        guard release.name == "@opencode/cli",
              OpenCodeProvider.versionComponents(release.version)?.first == 2,
              OpenCodeProvider.versionComponents(release.version)?.map(String.init).joined(separator: ".") == release.version,
              OpenCodeProvider.supportsVersion(release.version) else { throw OpenCodeInstallError.invalidRelease }
        let name = Self.packageName(appleSilicon: HostArchitecture.isAppleSilicon)
        let encodedName = name.replacingOccurrences(of: "/", with: "%2f")
        let package = try await metadata(at: URL(string: "https://registry.npmjs.org/\(encodedName)/\(release.version)")!)
        guard let url = Self.archiveURL(package: package, expectedName: name, version: release.version) else {
            throw OpenCodeInstallError.invalidRelease
        }
        let (archive, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 500 * 1024 * 1024 else { throw OpenCodeInstallError.invalidDownload }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard Self.verify(data, integrity: package.dist.integrity) else { throw OpenCodeInstallError.checksum }
        try Task.checkCancellation()
        let target = destination
        let version = release.version
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            // Only this exact entry reaches stdout. Archive paths never become
            // filesystem writes, and package scripts are never extracted/run.
            process.arguments = ["-xOzf", archive.path, "package/bin/opencode"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            var binary = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                guard binary.count + chunk.count <= 500 * 1024 * 1024 else {
                    if process.isRunning { process.terminate() }
                    process.waitUntilExit()
                    throw OpenCodeInstallError.extraction
                }
                binary.append(chunk)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, !binary.isEmpty else { throw OpenCodeInstallError.extraction }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staged = target.deletingLastPathComponent().appendingPathComponent(".opencode-\(UUID())")
            defer { try? FileManager.default.removeItem(at: staged) }
            try binary.write(to: staged, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            let probe = OpenCodeVersionProbe.run(staged)
            guard probe?.exitCode == 0,
                  probe.flatMap({ OpenCodeProvider.versionComponents($0.stdout) }) == OpenCodeProvider.versionComponents(version)
            else { throw OpenCodeInstallError.extraction }
            guard rename(staged.path, target.path) == 0 else { throw OpenCodeInstallError.extraction }
        }.value
        return version
    }
}
