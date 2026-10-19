import CryptoKit
import XCTest

final class PackagingRebrandTests: XCTestCase {
    func test_buildDmgUsesWhytapBundleNamesButKeepsStableIdentity() throws {
        let source = try readProjectFile("scripts/build-dmg.sh")

        XCTAssertTrue(source.contains(#"EXECUTABLE_NAME="Sidekey""#))
        XCTAssertTrue(source.contains(#"BUNDLE_ID="com.rootwise.sidekey.beta""#))
        XCTAssertTrue(source.contains(#"BUNDLE_ID="com.rootwise.sidekey""#))

        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Whytap-Beta""#))
        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Whytap""#))
        XCTAssertFalse(source.contains(#"APP_BUNDLE_NAME="Sidekey-Beta""#))
        XCTAssertFalse(source.contains(#"APP_BUNDLE_NAME="Sidekey""#))
    }

    func test_userReleaseScriptUsesWhytapArtifactNames() throws {
        // The release artifact names used to be passed by the GitHub Actions
        // workflow (.github/workflows/release.yml). That CI build is gone —
        // releases are cut locally via scripts/user-release.sh, which now owns
        // the flavor → APP_BUNDLE_NAME mapping. The rebrand invariant
        // (artifacts are "Whytap", never "Sidekey") lives there now.
        let source = try readProjectFile("scripts/user-release.sh")

        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Whytap""#))
        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Whytap-Beta""#))
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

    func test_devRunUsesWhytapDevBundleWithoutDeletingLegacyCopies() throws {
        let source = try readProjectFile("scripts/dev-run.sh")

        XCTAssertTrue(source.contains(#"APP_NAME="Sidekey""#))
        XCTAssertTrue(source.contains(#"EXECUTABLE_NAME="Sidekey""#))
        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Whytap-Beta-dev.app""#))
        XCTAssertFalse(source.contains("stop_conflicting_sidekey_processes"))
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
        let run = try runBuildFixture()
        XCTAssertEqual(run.result.status, 64, run.result.output)
        XCTAssertEqual(run.calls, "compiler\n")
        XCTAssertTrue(run.result.output.contains("Code signing: adhoc"), run.result.output)
    }

    // WHY: .project-docs/decisions/2026-10-19-community-signing-identity.md
    func test_communityCertificateBuildChecksItsKeyBeforeCompiling() throws {
        let identities = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: identities) }
        let identity = try makeSigningIdentity(in: identities, name: "release")
        let other = try makeSigningIdentity(in: identities, name: "other")

        let missing = try runBuildFixture(certificate: identity.certificate)
        XCTAssertEqual(missing.result.status, 1, missing.result.output)
        XCTAssertTrue(missing.result.output.contains("EXODIA_COMMUNITY_SIGNING_KEY"), missing.result.output)
        XCTAssertNil(missing.calls, missing.result.output)

        let mismatched = try runBuildFixture(certificate: identity.certificate,
            environment: ["EXODIA_COMMUNITY_SIGNING_KEY_FILE": other.key.path])
        XCTAssertEqual(mismatched.result.status, 1, mismatched.result.output)
        XCTAssertTrue(mismatched.result.output.contains("does not match"), mismatched.result.output)
        XCTAssertNil(mismatched.calls, mismatched.result.output)

        // The keychain is prepared only after compiling, so no security call precedes it.
        let matching = try runBuildFixture(certificate: identity.certificate,
            environment: ["EXODIA_COMMUNITY_SIGNING_KEY": try String(contentsOf: identity.key, encoding: .utf8)])
        XCTAssertEqual(matching.result.status, 64, matching.result.output)
        XCTAssertEqual(matching.calls, "compiler\n")
        XCTAssertTrue(matching.result.output.contains("Code signing: certificate:" + identity.sha1),
                      matching.result.output)

        let optedOut = try runBuildFixture(certificate: identity.certificate,
            environment: ["EXODIA_COMMUNITY_SIGNING": "adhoc"])
        XCTAssertEqual(optedOut.result.status, 64, optedOut.result.output)
        XCTAssertEqual(optedOut.calls, "compiler\n")
        XCTAssertTrue(optedOut.result.output.contains("Code signing: adhoc"), optedOut.result.output)
    }

    func test_communityPreflightReportsTheCommittedCertificate() throws {
        let identities = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: identities) }
        let identity = try makeSigningIdentity(in: identities, name: "release")
        let run = try runBuildFixture(certificate: identity.certificate, arguments: ["--preflight-only"])
        XCTAssertEqual(run.result.status, 0, run.result.output)
        XCTAssertNil(run.calls, run.result.output)
        let lastLine = try XCTUnwrap(run.result.output.split(separator: "\n").last)
        let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any])
        XCTAssertEqual(plan["code_signing"] as? String, "certificate:" + identity.sha1)
        XCTAssertEqual(plan["signing_certificate_sha1"] as? String, identity.sha1)
        XCTAssertEqual(plan["signing_key_configured"] as? Bool, false)
        XCTAssertEqual(plan["requires_apple_developer"] as? Bool, false)
    }

    /// Every community build's designated requirement pins this certificate's
    /// SHA-1 and macOS privacy grants follow that requirement. Another
    /// certificate makes every install grant Microphone and System Audio
    /// Recording again, so replacing it must be a deliberate rotation.
    func test_communitySigningCertificateIsPinned() throws {
        let pem = try readProjectFile("Resources/community-signing-certificate.pem")
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: body))
        let sha1 = Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sha1, "39da363652f6df4b52ac950998e16c98fd39bc6b",
                       "A new community certificate makes every install grant its macOS permissions again; rotate only for a leaked key")
    }

    /// `.gitignore` excludes `*.pem` as signing material, and the provenance check
    /// lists untracked but not ignored files. An ignored certificate would let a
    /// build sign with a file outside the release commit while a fresh clone signs
    /// ad hoc.
    func test_communitySigningCertificateIsNotIgnored() throws {
        let result = try runTool(URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", try projectRoot().path, "check-ignore", "--no-index", "-q",
                        "Resources/community-signing-certificate.pem"],
            environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
        if result.status == 128 {
            throw XCTSkip("not a Git checkout")
        }
        XCTAssertEqual(result.status, 1, "Git ignores Resources/community-signing-certificate.pem: \(result.output)")
    }

    func test_publishingRunRefusesLocalSigningOverrides() throws {
        for override in [["EXODIA_COMMUNITY_SIGNING": "adhoc"],
                         ["EXODIA_COMMUNITY_SIGNING_CERTIFICATE_FILE": "/nonexistent/test.pem"]] {
            let result = try runScript(try projectRoot().appendingPathComponent("scripts/user-release.sh"),
                environment: ["PATH": "/usr/bin:/bin", "FLAVOR": "prod"].merging(override) { $1 })
            XCTAssertEqual(result.status, 1, result.output)
            XCTAssertTrue(result.output.contains("are for local builds"), result.output)
        }
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
        try Data("test".utf8).write(to: temporary.appendingPathComponent("build/Whytap-9.9.9-build42.dmg"))
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
        <enclosure length="4" url="https://github.com/AbsoluteMode/whytap/releases/download/v9.9.9/Whytap-9.9.9-build42.dmg" />
        </item></channel></rss>
        XML
        """#)
        try executable(at: temporary.appendingPathComponent(".build/mock/sign_update"), contents: #"""
        #!/bin/bash
        echo unexpected-verification > "$PROBE_MARKER"
        exit 75
        """#)
        try prepareProvenanceFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg")
        let result = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
            environment: ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                "FLAVOR": "prod", "APP_BUNDLE_NAME": "Whytap", "SHORT_VERSION": "9.9.9",
                "BUILD_VERSION": "42", "PROBE_MARKER": marker.path,
                "SPARKLE_ED_PRIVATE_KEY": Data(repeating: 0, count: 32).base64EncodedString()])
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("refusing publication"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), result.output)
    }

    func test_publicationRequiresTheCommittedSigningIdentity() throws {
        let identities = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: identities) }
        let identity = try makeSigningIdentity(in: identities, name: "release")
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
        try FileManager.default.copyItem(at: identity.certificate,
            to: temporary.appendingPathComponent("Resources/community-signing-certificate.pem"))
        try Data("test".utf8).write(to: temporary.appendingPathComponent("build/Whytap-9.9.9-build42.dmg"))
        let marker = temporary.appendingPathComponent("publication-attempt.txt")
        try executable(at: temporary.appendingPathComponent("bin/gh"), contents: #"""
        #!/bin/bash
        if [ "$1 $2" = "auth status" ] || [ "$1 $2" = "release view" ]; then exit 0; fi
        echo unexpected-upload > "$PROBE_MARKER"
        exit 74
        """#)
        try prepareProvenanceFixture(temporary)
        let environment = ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                           "FLAVOR": "prod", "APP_BUNDLE_NAME": "Whytap", "SHORT_VERSION": "9.9.9",
                           "BUILD_VERSION": "42", "PROBE_MARKER": marker.path]

        XCTAssertNotEqual(try sealFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg",
                                          codeSigning: "certificate:ABC", expectSuccess: false), 0)
        try sealFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg", codeSigning: "adhoc")
        let adhoc = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
                                  environment: environment)
        XCTAssertNotEqual(adhoc.status, 0)
        XCTAssertTrue(adhoc.output.contains("archive code signing does not match"), adhoc.output)

        // The upload derives the same identity from the committed certificate,
        // passes provenance and stops only at the existing-release guard.
        try sealFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg",
                        codeSigning: "certificate:" + identity.sha1)
        let signed = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
                                   environment: environment)
        XCTAssertNotEqual(signed.status, 0)
        XCTAssertTrue(signed.output.contains("already exists; refusing to overwrite"), signed.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), signed.output)
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
        try Data("test".utf8).write(to: temporary.appendingPathComponent("build/Whytap-9.9.9-build42.dmg"))
        let marker = temporary.appendingPathComponent("publication-attempt.txt")
        try executable(at: temporary.appendingPathComponent("bin/gh"), contents: #"""
        #!/bin/bash
        if [ "$1 $2" = "auth status" ] || [ "$1 $2" = "release view" ]; then exit 0; fi
        echo unexpected-upload > "$PROBE_MARKER"
        exit 74
        """#)
        try prepareProvenanceFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg")
        let result = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
            environment: ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                "FLAVOR": "prod", "APP_BUNDLE_NAME": "Whytap", "SHORT_VERSION": "9.9.9",
                "BUILD_VERSION": "42", "PROBE_MARKER": marker.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("already exists; refusing to overwrite"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), result.output)
    }

    private func runScript(_ script: URL, arguments: [String] = [],
                           environment: [String: String]) throws -> (status: Int32, output: String) {
        try runTool(URL(fileURLWithPath: "/bin/bash"), arguments: [script.path] + arguments,
                    environment: environment)
    }

    private func runTool(_ executable: URL, arguments: [String],
                         environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain while the child is running: even short preflight output can
        // fill a pipe when the OS is under pipe-memory pressure.
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: bytes, as: UTF8.self))
    }

    /// Runs build-dmg.sh in a minimal committed checkout whose compiler stub exits 64.
    /// `calls` lists the stubbed compiler and Apple tools that ran, nil when none did.
    private func runBuildFixture(certificate: URL? = nil, arguments: [String] = [],
                                 environment: [String: String] = [:]) throws
        -> (result: (status: Int32, output: String), calls: String?) {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let tools = temporary.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let marker = temporary.appendingPathComponent("calls.txt")
        let root = try projectRoot()
        for relative in ["scripts/build-dmg.sh", "VERSION", "Package.resolved",
                         "Resources/Info.plist.template", "Resources/sparkle-public-ed-key.txt",
                         "Resources/blocknote/index.html"] {
            let destination = temporary.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent(relative), to: destination)
        }
        if let certificate {
            try FileManager.default.copyItem(at: certificate,
                to: temporary.appendingPathComponent("Resources/community-signing-certificate.pem"))
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
        try prepareProvenanceFixture(temporary)
        let result = try runScript(temporary.appendingPathComponent("scripts/build-dmg.sh"),
            arguments: arguments,
            environment: ["PATH": tools.path + ":/usr/bin:/bin", "PROBE_MARKER": marker.path,
                          "BUILD_VERSION": "42", "FLAVOR": "prod"].merging(environment) { $1 })
        return (result, try? String(contentsOf: marker, encoding: .utf8))
    }

    /// A throwaway self-signed code-signing identity like the community one.
    private func makeSigningIdentity(in directory: URL, name: String) throws
        -> (certificate: URL, key: URL, sha1: String) {
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        let key = directory.appendingPathComponent(name + "-key.pem")
        let certificate = directory.appendingPathComponent(name + "-certificate.pem")
        let created = try runTool(openssl, arguments: ["req", "-x509", "-newkey", "rsa:2048", "-sha256",
            "-days", "2", "-nodes", "-keyout", key.path, "-out", certificate.path,
            "-subj", "/CN=Whytap Test Signing " + name,
            "-addext", "basicConstraints=critical,CA:false",
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=critical,codeSigning"], environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(created.status, 0, created.output)
        let fingerprint = try runTool(openssl, arguments: ["x509", "-in", certificate.path, "-noout",
            "-fingerprint", "-sha1"], environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(fingerprint.status, 0, fingerprint.output)
        let sha1 = String(fingerprint.output.split(separator: "=").last ?? "")
            .replacingOccurrences(of: ":", with: "").lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(sha1.count, 40, fingerprint.output)
        return (certificate, key, sha1)
    }

    private func prepareProvenanceFixture(_ directory: URL, archiveName: String? = nil) throws {
        let helper = directory.appendingPathComponent("scripts/release-provenance.py")
        try FileManager.default.copyItem(at: try projectRoot().appendingPathComponent("scripts/release-provenance.py"),
            to: helper)
        try "build/\n.build/\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        for arguments in [["init", "-q"], ["config", "user.name", "Release Fixture"],
                          ["config", "user.email", "fixture@example.invalid"],
                          ["config", "commit.gpgsign", "false"], ["config", "core.hooksPath", "/dev/null"],
                          ["config", "core.fsmonitor", "false"], ["add", "."], ["commit", "-qm", "fixture"]] {
            let result = try runTool(URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", directory.path] + arguments, environment: environment)
            XCTAssertEqual(result.status, 0, result.output)
        }
        if let archiveName {
            try sealFixture(directory, archiveName: archiveName, codeSigning: "adhoc")
        }
    }

    @discardableResult
    private func sealFixture(_ directory: URL, archiveName: String, codeSigning: String,
                             expectSuccess: Bool = true) throws -> Int32 {
        let helper = directory.appendingPathComponent("scripts/release-provenance.py")
        let environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let captured = try runTool(URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [helper.path, "capture", "--project-root", directory.path], environment: environment)
        XCTAssertEqual(captured.status, 0, captured.output)
        let result = try runTool(URL(fileURLWithPath: "/usr/bin/python3"), arguments: [helper.path, "seal",
            "--project-root", directory.path, "--source-sha", captured.output.trimmingCharacters(in: .whitespacesAndNewlines),
            "--archive", directory.appendingPathComponent("build/" + archiveName).path,
            "--version", "9.9.9", "--build", "42", "--flavor", "prod", "--distribution", "community",
            "--code-signing", codeSigning],
            environment: environment)
        if expectSuccess {
            XCTAssertEqual(result.status, 0, result.output)
        } else {
            XCTAssertTrue(result.output.contains("code signing must be"), result.output)
        }
        return result.status
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
