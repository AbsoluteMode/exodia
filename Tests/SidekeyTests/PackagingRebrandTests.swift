import XCTest

final class PackagingRebrandTests: XCTestCase {
    func test_buildDmgUsesExodiaBundleNamesButKeepsStableIdentity() throws {
        let source = try readProjectFile("scripts/build-dmg.sh")

        XCTAssertTrue(source.contains(#"EXECUTABLE_NAME="Sidekey""#))
        XCTAssertTrue(source.contains(#"BUNDLE_ID="com.rootwise.sidekey.beta""#))
        XCTAssertTrue(source.contains(#"BUNDLE_ID="com.rootwise.sidekey""#))

        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Exodia-Beta""#))
        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Exodia""#))
        XCTAssertFalse(source.contains(#"APP_BUNDLE_NAME="Sidekey-Beta""#))
        XCTAssertFalse(source.contains(#"APP_BUNDLE_NAME="Sidekey""#))
    }

    func test_userReleaseScriptUsesExodiaArtifactNames() throws {
        // The release artifact names used to be passed by the GitHub Actions
        // workflow (.github/workflows/release.yml). That CI build is gone —
        // releases are cut locally via scripts/user-release.sh, which now owns
        // the flavor → APP_BUNDLE_NAME mapping. The rebrand invariant
        // (artifacts are "Exodia", never "Sidekey") lives there now.
        let source = try readProjectFile("scripts/user-release.sh")

        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Exodia""#))
        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Exodia-Beta""#))
        XCTAssertFalse(source.contains(#"APP_BUNDLE_NAME="Sidekey""#))
        XCTAssertFalse(source.contains(#"APP_BUNDLE_NAME="Sidekey-Beta""#))
    }

    func test_uploadReleasePublishesToGitHubReleasesWithLatestAlias() throws {
        // Releases live on GitHub Releases: the versioned DMG, a stable
        // `<Bundle>-latest.dmg` alias and the signed appcast are assets of
        // the release. No object storage, no legacy Sidekey aliases.
        let source = try readProjectFile("scripts/upload-release.sh")

        XCTAssertTrue(source.contains("gh release create"))
        XCTAssertTrue(source.contains("generate_appcast"))
        XCTAssertTrue(source.contains(#"LATEST_FILENAME="${APP_BUNDLE_NAME}-latest.dmg""#))
        XCTAssertTrue(source.contains("releases/latest/download/appcast.xml"))
        XCTAssertFalse(source.contains("Sidekey-latest.dmg"))
        XCTAssertFalse(source.contains("aws s3"))
        XCTAssertFalse(source.contains("updates.whytap.ai"))
    }

    func test_devRunUsesExodiaDevBundleAndCleansOldSidekeyBundles() throws {
        let source = try readProjectFile("scripts/dev-run.sh")

        XCTAssertTrue(source.contains(#"APP_NAME="Sidekey""#))
        XCTAssertTrue(source.contains(#"EXECUTABLE_NAME="Sidekey""#))
        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Exodia-Beta-dev.app""#))
        XCTAssertTrue(source.contains("build/Sidekey-Beta-dev.app"))
    }

    /// Regression guard for the silent system-audio failure (June 2026): the
    /// CoreAudio process tap that records the other meeting participants is
    /// gated by the TCC "System Audio Recording" permission, and macOS only
    /// shows that permission prompt when `NSAudioCaptureUsageDescription` is
    /// present in Info.plist. When the key is missing the tap still starts
    /// without any error and delivers all-zero buffers forever — meetings
    /// lose the other party with no diagnostic. The key was lost once during
    /// the SCStream → process-tap migration; never let it drop again.
    func test_infoPlistDeclaresSystemAudioCaptureUsageForMeetingTap() throws {
        let source = try readProjectFile("Resources/Info.plist.template")

        XCTAssertTrue(
            source.contains("<key>NSAudioCaptureUsageDescription</key>"),
            "NSAudioCaptureUsageDescription is required for the meeting system-audio tap TCC prompt; without it the tap silently records zeros"
        )
        // The prompt also needs a human-readable, non-placeholder reason.
        let pattern = "<key>NSAudioCaptureUsageDescription</key>\\s*<string>[^<]{10,}</string>"
        XCTAssertNotNil(
            source.range(of: pattern, options: .regularExpression),
            "NSAudioCaptureUsageDescription must carry a non-empty usage string"
        )
    }

    func test_releaseBuildDoesNotClaimRestrictedKeychainEntitlementsWithoutProvisioningProfile() throws {
        let source = try readProjectFile("scripts/build-dmg.sh")

        XCTAssertFalse(source.contains("RELEASE_ENTITLEMENTS"))
        XCTAssertFalse(source.contains("com.apple.developer.team-identifier"))
        XCTAssertFalse(source.contains("com.apple.application-identifier"))
        XCTAssertFalse(source.contains("${TEAM_ID}.${BUNDLE_ID}"))
    }

    func test_communityPreflightDoesNotRequireAppleCredentials() throws {
        for script in ["scripts/build-dmg.sh", "scripts/user-release.sh"] {
            let result = try runScript(try projectRoot().appendingPathComponent(script),
                arguments: ["--preflight-only"],
                environment: ["PATH": "/usr/bin:/bin", "FLAVOR": "prod", "BUILD_VERSION": "42"])
            XCTAssertEqual(result.status, 0, result.output)
            let lastLine = try XCTUnwrap(result.output.split(separator: "\n").last)
            let data = Data(lastLine.utf8)
            let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(plan["distribution"] as? String, "community")
            XCTAssertEqual(plan["requires_apple_developer"] as? Bool, false)
            XCTAssertEqual(plan["requires_notarization"] as? Bool, false)
            XCTAssertEqual(plan["architectures"] as? [String], ["arm64", "x86_64"])
            XCTAssertEqual(plan["bundle_id"] as? String, "com.rootwise.sidekey")
        }
    }

    func test_communityBuildReachesCompilerWithoutAppleTools() throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let tools = temporary.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let marker = temporary.appendingPathComponent("calls.txt")
        let root = try projectRoot()
        for relative in ["scripts/build-dmg.sh", "scripts/build-metallib.sh", "VERSION", "Package.resolved",
                         "Resources/Info.plist.template", "Resources/sparkle-public-ed-key.txt",
                         "Resources/blocknote/index.html", "Resources/mlx.metallib", "Resources/mlx.metallib.revision"] {
            let destination = temporary.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent(relative), to: destination)
        }
        try executable(at: tools.appendingPathComponent("swift"), contents: #"""
        #!/bin/bash
        echo compiler >> "$PROBE_MARKER"
        exit 64
        """#)
        try executable(at: tools.appendingPathComponent("security"), contents: #"""
        #!/bin/bash
        echo unexpected-apple >> "$PROBE_MARKER"
        exit 71
        """#)
        try executable(at: tools.appendingPathComponent("xcrun"), contents: #"""
        #!/bin/bash
        if [ "$*" = "--sdk macosx --show-sdk-version" ]; then
            echo 26.4
            exit 0
        fi
        echo unexpected-apple >> "$PROBE_MARKER"
        exit 71
        """#)
        let result = try runScript(temporary.appendingPathComponent("scripts/build-dmg.sh"),
            environment: ["PATH": tools.path + ":/usr/bin:/bin", "PROBE_MARKER": marker.path,
                          "BUILD_VERSION": "42", "FLAVOR": "prod"])
        XCTAssertEqual(result.status, 64, result.output)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "compiler\n")
    }

    func test_developerIDPathRequiresExplicitLegacyOptIn() throws {
        let result = try runScript(try projectRoot().appendingPathComponent("scripts/build-dmg.sh"),
            arguments: ["--preflight-only"], environment: ["PATH": "/usr/bin:/bin",
                "EXODIA_LEGACY_SIGNED_RELEASE": "1", "BUILD_VERSION": "42"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("TEAM_ID"), result.output)
    }

    func test_publicationRejectsUnsignedAppcastBeforeUploading() throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        for directory in ["scripts", "Resources", "build", "bin", ".build/mock"] {
            try FileManager.default.createDirectory(at: temporary.appendingPathComponent(directory),
                withIntermediateDirectories: true)
        }
        let root = try projectRoot()
        try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/upload-release.sh"),
            to: temporary.appendingPathComponent("scripts/upload-release.sh"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("Resources/Info.plist.template"),
            to: temporary.appendingPathComponent("Resources/Info.plist.template"))
        try Data("test".utf8).write(to: temporary.appendingPathComponent("build/Exodia-9.9.9-build42.dmg"))
        let marker = temporary.appendingPathComponent("publication-attempt.txt")
        try executable(at: temporary.appendingPathComponent("bin/gh"), contents: #"""
        #!/bin/bash
        if [ "$1 $2" = "auth status" ]; then exit 0; fi
        if [ "$1 $2" = "release download" ]; then exit 1; fi
        if [ "$1 $2" = "release view" ] || [ "$1" = "api" ]; then exit 1; fi
        echo unexpected-upload > "$PROBE_MARKER"
        exit 74
        """#)
        try executable(at: temporary.appendingPathComponent(".build/mock/generate_appcast"), contents: #"""
        #!/bin/bash
        for staging in "$@"; do :; done
        cat > "$staging/appcast.xml" <<'XML'
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>42</sparkle:version><sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
        <enclosure length="4" url="https://github.com/AbsoluteMode/exodia/releases/download/v9.9.9/Exodia-9.9.9-build42.dmg" />
        </item></channel></rss>
        XML
        """#)
        try executable(at: temporary.appendingPathComponent(".build/mock/sign_update"), contents: #"""
        #!/bin/bash
        echo unexpected-verification > "$PROBE_MARKER"
        exit 75
        """#)
        let result = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
            environment: ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                "FLAVOR": "prod", "APP_BUNDLE_NAME": "Exodia", "SHORT_VERSION": "9.9.9",
                "BUILD_VERSION": "42", "PROBE_MARKER": marker.path,
                "SPARKLE_ED_PRIVATE_KEY": Data(repeating: 0, count: 32).base64EncodedString()])
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("refusing publication"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), result.output)
    }

    func test_publicationRefusesExistingVersionBeforeKeysOrUpload() throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        for directory in ["scripts", "Resources", "build", "bin"] {
            try FileManager.default.createDirectory(at: temporary.appendingPathComponent(directory),
                withIntermediateDirectories: true)
        }
        let root = try projectRoot()
        for relative in ["scripts/upload-release.sh", "Resources/Info.plist.template"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(relative),
                to: temporary.appendingPathComponent(relative))
        }
        try Data("test".utf8).write(to: temporary.appendingPathComponent("build/Exodia-9.9.9-build42.dmg"))
        let marker = temporary.appendingPathComponent("publication-attempt.txt")
        try executable(at: temporary.appendingPathComponent("bin/gh"), contents: #"""
        #!/bin/bash
        if [ "$1 $2" = "auth status" ] || [ "$1 $2" = "release view" ]; then exit 0; fi
        echo unexpected-upload > "$PROBE_MARKER"
        exit 74
        """#)
        let result = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
            environment: ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                "FLAVOR": "prod", "APP_BUNDLE_NAME": "Exodia", "SHORT_VERSION": "9.9.9",
                "BUILD_VERSION": "42", "PROBE_MARKER": marker.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("already exists; refusing to overwrite"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), result.output)
    }

    private func runScript(_ script: URL, arguments: [String] = [],
                           environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExodiaPackagingTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func executable(at path: URL, contents: String) throws {
        try (contents + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    private func readProjectFile(_ relativePath: String) throws -> String {
        let url = try projectRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "PackagingRebrandTests", code: 1)
    }
}
