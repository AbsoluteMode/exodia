import CryptoKit
import XCTest
@testable import Sidekey

/// Completeness and content validation: application-owned bytes are either in
/// the archive or the backup fails, and an archive's contents are proven
/// usable before anything is parked or replaced.
@MainActor
final class ArtifactBackupCoverageTests: XCTestCase {
    private var profiles: [ArtifactBackupTestProfile] = []
    private var openMeetingStores: [MeetingsStore] = []

    override func tearDown() async throws {
        for store in openMeetingStores { await store.close() }
        openMeetingStores.removeAll()
        profiles.forEach { $0.tearDown() }
        profiles.removeAll()
    }

    private func profile() throws -> ArtifactBackupTestProfile {
        let result = try ArtifactBackupTestProfile()
        profiles.append(result)
        return result
    }

    private func archive(in profile: ArtifactBackupTestProfile) -> URL {
        profile.root.appendingPathComponent("archive-\(UUID().uuidString).exodiabackup")
    }

    private func manifest(of url: URL, key: Data) throws -> ArtifactBackupManifest {
        try ArtifactRestoreTransaction.validateArchive(at: url, key: key)
    }

    // MARK: - Owned Notify and Monitor bytes

    private let cacheTag = "Signature: 8a477f597d28d172789f06886806bc55\n# Rebuildable worker dependencies\n"

    func testTaggedPythonEnvironmentDoesNotBlockBackupAndWorkingFilesRoundTrip() async throws {
        let source = try profile(), target = try profile()
        let worker = source.locations.notifyRoot.appendingPathComponent("workers/example")
        let environment = worker.appendingPathComponent("venv")
        try source.write("print('worker')", to: worker.appendingPathComponent("main.py"))
        try source.write("{\"cursor\":42}", to: worker.appendingPathComponent("state.json"))
        try source.write(cacheTag, to: environment.appendingPathComponent("CACHEDIR.TAG"))
        try source.write("generated", to: environment.appendingPathComponent(".lock"))
        try source.write("generated", to: environment.appendingPathComponent("lib/python/site-packages/pkg/deep/file.py"))
        try FileManager.default.createDirectory(at: environment.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: environment.appendingPathComponent("bin/python").path,
                                                 withDestinationPath: "/nonexistent/python")
        let url = archive(in: source), key = ArtifactBackupTestKeys.make()
        let engine = ArtifactBackupEngine(environment: source.environment())
        _ = try await engine.createArchive(at: url, key: key, sections: [.workspace])
        let paths = Set(try manifest(of: url, key: key).entries.map(\.path))
        XCTAssertTrue(paths.contains("workspace/notify/workers/example/main.py"))
        XCTAssertTrue(paths.contains("workspace/notify/workers/example/state.json"))
        XCTAssertFalse(paths.contains { $0.contains("/venv/") })
        let preview = try await engine.inspectArchive(at: url, key: key)
        XCTAssertTrue(preview.warnings.contains { $0.contains("1 explicitly tagged cache") })
        let targetEnvironment = target.environment()
        try await ArtifactBackupEngine(environment: targetEnvironment)
            .stageRestore(from: url, key: key, sections: [.workspace])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: targetEnvironment)
        let restored = target.locations.notifyRoot.appendingPathComponent("workers/example")
        XCTAssertEqual(target.contents(of: restored.appendingPathComponent("main.py")), "print('worker')")
        XCTAssertEqual(target.contents(of: restored.appendingPathComponent("state.json")), "{\"cursor\":42}")
        XCTAssertFalse(target.exists(restored.appendingPathComponent("venv")))
    }

    func testHiddenTaggedCacheIsRecognizedBeforeArchiveNameValidation() async throws {
        let source = try profile()
        let root = source.locations.monitorRoot
        try source.write("{}", to: root.appendingPathComponent("dashboards/board.json"))
        try source.write(cacheTag, to: root.appendingPathComponent(".cache/CACHEDIR.TAG"))
        try source.write("generated", to: root.appendingPathComponent(".cache/.lock"))
        let url = archive(in: source), key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment())
            .createArchive(at: url, key: key, sections: [.workspace])
        let paths = Set(try manifest(of: url, key: key).entries.map(\.path))
        XCTAssertEqual(paths, ["workspace/monitor/dashboards/board.json"])
    }

    func testEnvironmentNameOrInvalidCacheTagDoesNotBypassSafetyChecks() async throws {
        for tag in ["", "Signature: not-a-cache"] {
            let source = try profile()
            let environment = source.locations.notifyRoot.appendingPathComponent("venv")
            try source.write("unknown data", to: environment.appendingPathComponent(".lock"))
            if !tag.isEmpty { try source.write(tag, to: environment.appendingPathComponent("CACHEDIR.TAG")) }
            do {
                _ = try await ArtifactBackupEngine(environment: source.environment())
                    .createArchive(at: archive(in: source), key: ArtifactBackupTestKeys.make(), sections: [.workspace])
                XCTFail("An untagged directory must not be silently omitted")
            } catch { XCTAssertEqual(error as? ArtifactBackupError, .unsupportedFile("Notifications/venv/.lock")) }
        }
    }

    func testSymlinkedCacheTagCannotExcludeWorkingFiles() async throws {
        let source = try profile()
        let tag = source.root.appendingPathComponent("real-tag")
        try source.write(cacheTag, to: tag)
        let worker = source.locations.notifyRoot.appendingPathComponent("workers/example")
        try source.write("owned", to: worker.appendingPathComponent("main.py"))
        try FileManager.default.createSymbolicLink(atPath: worker.appendingPathComponent("CACHEDIR.TAG").path,
                                                 withDestinationPath: tag.path)
        do {
            _ = try await ArtifactBackupEngine(environment: source.environment())
                .createArchive(at: archive(in: source), key: ArtifactBackupTestKeys.make(), sections: [.workspace])
            XCTFail("A linked tag must not make a directory disappear")
        } catch { XCTAssertEqual(error as? ArtifactBackupError, .unsupportedFile("Notifications/workers/example/CACHEDIR.TAG")) }
    }

    func testChangeProbeIgnoresTaggedCacheChurnButTracksWorkingFiles() throws {
        let source = try profile()
        let root = source.locations.notifyRoot
        try source.write("script", to: root.appendingPathComponent("main.py"))
        try source.write(cacheTag, to: root.appendingPathComponent("venv/CACHEDIR.TAG"))
        try source.write("old", to: root.appendingPathComponent("venv/.lock"))
        let before = BackupChangeProbe.stamp(locations: source.locations)
        try source.write("new cache content", to: root.appendingPathComponent("venv/.lock"))
        try source.write("new package", to: root.appendingPathComponent("venv/lib/python/pkg.py"))
        XCTAssertEqual(BackupChangeProbe.stamp(locations: source.locations), before)
        try source.write("changed script", to: root.appendingPathComponent("main.py"))
        XCTAssertNotEqual(BackupChangeProbe.stamp(locations: source.locations), before)

        let recording = source.locations.meetingsStaging.appendingPathComponent(UUID().uuidString)
        try source.write(cacheTag, to: recording.appendingPathComponent("CACHEDIR.TAG"))
        try source.write("audio", to: recording.appendingPathComponent("chunk-000.wav"))
        let withRecording = BackupChangeProbe.stamp(locations: source.locations)
        try source.write("more audio", to: recording.appendingPathComponent("chunk-000.wav"))
        XCTAssertNotEqual(BackupChangeProbe.stamp(locations: source.locations), withRecording,
                          "A cache marker must never hide retained recording changes")
    }

    func testNestedWorkerScriptsCursorsAndLargeLogosAreAllIncluded() async throws {
        let source = try profile()
        try source.write("#!/usr/bin/env python3\nprint('hi')",
                         to: source.locations.notifyRoot.appendingPathComponent("workers/telegram/main.py"))
        try source.write("{\"cursor\":42}",
                         to: source.locations.notifyRoot.appendingPathComponent("workers/telegram/state.json"))
        try source.write("# guide", to: source.locations.notifyRoot.appendingPathComponent("README.md"))
        // A logo at the documented 2 MiB maximum must not be dropped.
        try source.write(Data(repeating: 0x89, count: 2 * 1024 * 1024),
                         to: source.locations.notifyRoot.appendingPathComponent("logos/big.png"))
        let url = archive(in: source)
        let key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment())
            .createArchive(at: url, key: key, sections: [.workspace])
        let paths = Set(try manifest(of: url, key: key).entries.map(\.path))
        XCTAssertTrue(paths.contains("workspace/notify/workers/telegram/main.py"))
        XCTAssertTrue(paths.contains("workspace/notify/workers/telegram/state.json"))
        XCTAssertTrue(paths.contains("workspace/notify/README.md"))
        XCTAssertTrue(paths.contains("workspace/notify/logos/big.png"))

        let target = try profile()
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: url, key: key, sections: [.workspace])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(target.contents(of: target.locations.notifyRoot
            .appendingPathComponent("workers/telegram/state.json")), "{\"cursor\":42}")
        XCTAssertEqual(try Data(contentsOf: target.locations.notifyRoot
            .appendingPathComponent("logos/big.png")).count, 2 * 1024 * 1024)
    }

    func testBackupAfterRestoreRetainsInertRecordsAndExcludesMultipartUploadBodies() async throws {
        let source = try profile(), target = try profile(), third = try profile()
        let meetings = try MeetingsStore(rootDirectory: source.locations.meetingsCatalog)
        openMeetingStores.append(meetings)
        let id = UUID().uuidString
        let recording = source.locations.meetingsStaging.appendingPathComponent(id)
        let parked = "manifest.json.restored-inactive"
        try source.write("retained record", to: recording.appendingPathComponent(parked))
        try source.write("retained audio", to: recording.appendingPathComponent("chunk-000.wav"))
        let held = "manifest.json.held-20000101-000000"
        let repaired = "soniox-transcription.json.pre-realign-20000101-000000"
        try source.write("held original", to: recording.appendingPathComponent(held))
        try source.write("earlier checkpoint", to: recording.appendingPathComponent(repaired))
        try source.write("original mixed audio", to: recording.appendingPathComponent("orig-mixed-20000101/chunk-000.wav"))
        try source.write("nested original record", to: recording.appendingPathComponent("orig-mixed-20000101/manifest.json"))
        try source.write("Finder metadata", to: source.locations.meetingsStaging.appendingPathComponent(".DS_Store"))
        try source.write("active remote job", to: recording.appendingPathComponent("soniox-transcription.json"))
        let upload = recording.appendingPathComponent("soniox-upload-\(UUID().uuidString).tmp")
        try source.write("disposable multipart", to: upload)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: upload.path)
        try source.write("preserved source", to: source.locations.notifyRoot
            .appendingPathComponent("sources/example.json.restored-invalid"))
        try source.write("guide", to: source.locations.notifyRoot.appendingPathComponent("sources/README.md"))
        let key = ArtifactBackupTestKeys.make(), first = archive(in: source)
        let sourceEngine = ArtifactBackupEngine(environment: source.environment(meetings: meetings))
        _ = try await sourceEngine.createArchive(at: first, key: key, sections: [.workspace, .meetings])
        let entries = try manifest(of: first, key: key).entries
        XCTAssertFalse(entries.contains { $0.path.contains("soniox-upload-") })
        for entry in entries { XCTAssertNoThrow(try ArtifactRestoreDestination.resolve(entry.path, in: target.locations)) }
        let targetEnvironment = target.environment()
        try await ArtifactBackupEngine(environment: targetEnvironment)
            .stageRestore(from: first, key: key, sections: [.workspace, .meetings])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: targetEnvironment)

        let targetMeetings = try MeetingsStore(rootDirectory: target.locations.meetingsCatalog)
        openMeetingStores.append(targetMeetings)
        let second = archive(in: target)
        let targetEngine = ArtifactBackupEngine(environment: target.environment(meetings: targetMeetings))
        _ = try await targetEngine.createArchive(at: second, key: key, sections: [.workspace, .meetings])
        _ = try await targetEngine.inspectArchive(at: second, key: key)
        let thirdEnvironment = third.environment()
        try await ArtifactBackupEngine(environment: thirdEnvironment)
            .stageRestore(from: second, key: key, sections: [.workspace, .meetings])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: thirdEnvironment)
        XCTAssertEqual(third.contents(of: third.locations.meetingsStaging.appendingPathComponent("\(id)/\(parked)")), "retained record")
        XCTAssertFalse(third.exists(third.locations.meetingsStaging.appendingPathComponent("\(id)/manifest.json")))
        XCTAssertFalse(third.exists(third.locations.meetingsStaging.appendingPathComponent("\(id)/soniox-transcription.json")))
        XCTAssertEqual(third.contents(of: third.locations.meetingsStaging.appendingPathComponent("\(id)/\(held)")), "held original")
        XCTAssertEqual(third.contents(of: third.locations.meetingsStaging.appendingPathComponent("\(id)/\(repaired)")), "earlier checkpoint")
        XCTAssertEqual(third.contents(of: third.locations.meetingsStaging.appendingPathComponent("\(id)/orig-mixed-20000101/chunk-000.wav")), "original mixed audio")
        XCTAssertEqual(third.contents(of: third.locations.meetingsStaging.appendingPathComponent("\(id)/orig-mixed-20000101/manifest.json")), "nested original record")
        XCTAssertThrowsError(try ArtifactRestoreDestination.resolve("meetings/staged/\(id)/SONIOX-TRANSCRIPTION.JSON", in: third.locations))
        XCTAssertEqual(third.contents(of: third.locations.notifyRoot
            .appendingPathComponent("sources/example.json.restored-invalid")), "preserved source")
    }

    func testActiveAndEarlierInactiveConfigurationsBothSurviveRecovery() async throws {
        let source = try profile(), target = try profile()
        try source.write("active servers", to: source.locations.monitorRoot.appendingPathComponent("servers.json"))
        try source.write("earlier servers", to: source.locations.monitorRoot.appendingPathComponent("servers.json.restored-inactive"))
        try source.write("unreadable new source", to: source.locations.notifyRoot.appendingPathComponent("sources/example.json"))
        try source.write("earlier source", to: source.locations.notifyRoot.appendingPathComponent("sources/example.json.restored-invalid"))
        let key = ArtifactBackupTestKeys.make(), file = archive(in: source)
        let engine = ArtifactBackupEngine(environment: source.environment())
        _ = try await engine.createArchive(at: file, key: key, sections: [.workspace])
        _ = try await engine.inspectArchive(at: file, key: key)
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: file, key: key, sections: [.workspace])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(target.contents(of: target.locations.monitorRoot.appendingPathComponent("servers.json.restored-inactive")), "active servers")
        XCTAssertEqual(target.contents(of: target.locations.notifyRoot.appendingPathComponent("sources/example.json.restored-invalid")), "unreadable new source")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: target.locations.bundleRoot,
            includingPropertiesForKeys: [.isRegularFileKey]))
        var retained: [String] = []
        for case let url as URL in enumerator where url.path.contains("/restored-files-") {
            if let value = target.contents(of: url) { retained.append(value) }
        }
        XCTAssertTrue(retained.contains("earlier servers"))
        XCTAssertTrue(retained.contains("earlier source"))
        XCTAssertFalse(target.exists(target.locations.monitorRoot.appendingPathComponent("servers.json")))
        XCTAssertFalse(target.exists(target.locations.notifyRoot.appendingPathComponent("sources/example.json")))
    }

    func testUnchangedRetainedGenerationsHaveAStableContentFingerprint() async throws {
        let source = try profile()
        let recording = source.locations.meetingsStaging.appendingPathComponent(UUID().uuidString)
        try source.write("active record", to: recording.appendingPathComponent("manifest.json"))
        try source.write("earlier record", to: recording.appendingPathComponent("manifest.json.restored-inactive"))
        try source.write("already retained", to: recording.appendingPathComponent("manifest-retained-0.json.restored-inactive"))
        try source.write("current", to: source.locations.monitorRoot.appendingPathComponent("servers.json"))
        try source.write("previous", to: source.locations.monitorRoot.appendingPathComponent("servers.json.restored-inactive"))
        try source.write("retained", to: source.locations.monitorRoot.appendingPathComponent("restored-files-retained-0/note.txt"))
        let engine = ArtifactBackupEngine(environment: source.environment()), key = ArtifactBackupTestKeys.make()
        let first = try await engine.createArchive(at: archive(in: source), key: key)
        let secondFile = archive(in: source)
        let second = try await engine.createArchive(at: secondFile, key: key)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.contentFingerprint, second.contentFingerprint)
        let unchangedFile = archive(in: source)
        let unchanged = try await engine.createArchiveIfChanged(at: unchangedFile, key: key,
                                                                previousFingerprint: second.contentFingerprint)
        XCTAssertNil(unchanged)
        XCTAssertFalse(source.exists(unchangedFile), "Unchanged content does not produce another encrypted archive")
        try source.write("changed!", to: source.locations.monitorRoot.appendingPathComponent("servers.json"))
        let changed = try await engine.createArchiveIfChanged(at: unchangedFile, key: key,
                                                              previousFingerprint: second.contentFingerprint)
        XCTAssertNotNil(changed)
        XCTAssertNotEqual(changed?.contentFingerprint, second.contentFingerprint)
    }

    func testNestedRetainedRecordingLinksAreRejectedWithoutFollowingThem() async throws {
        let source = try profile(), id = UUID().uuidString
        let outside = source.root.appendingPathComponent("outside.wav")
        try source.write("outside", to: outside)
        let folder = source.locations.meetingsStaging.appendingPathComponent("\(id)/originals")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("audio.wav").path,
                                                   withDestinationPath: outside.path)
        let file = archive(in: source)
        do {
            _ = try await ArtifactBackupEngine(environment: source.environment())
                .createArchive(at: file, key: ArtifactBackupTestKeys.make(), sections: [.meetings])
            XCTFail("Never follow links in retained originals")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError, .unsupportedFile("Recordings/\(id)/originals/audio.wav"))
        }
        XCTAssertFalse(source.exists(file))
        XCTAssertEqual(source.contents(of: outside), "outside")
    }

    func testLegacyArchiveWithActiveAndInactiveConfigurationPreservesBoth() async throws {
        let target = try profile(), key = ArtifactBackupTestKeys.make(), file = archive(in: target)
        _ = try ArtifactBackupTestArchive.make(at: file, key: key, entries: [
            ("workspace/monitor/servers.json", .workspace, Data("current".utf8)),
            ("workspace/monitor/servers.json.restored-inactive", .workspace, Data("previous".utf8)),
            ("workspace/notify/sources/demo.json", .workspace, Data("unreadable current".utf8)),
            ("workspace/notify/sources/demo.json.restored-invalid", .workspace, Data("previous source".utf8))
        ], schema: 2)
        let environment = target.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        _ = try await engine.inspectArchive(at: file, key: key)
        try await engine.stageRestore(from: file, key: key, sections: [.workspace])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(target.contents(of: target.locations.monitorRoot.appendingPathComponent("servers.json.restored-inactive")), "current")
        XCTAssertEqual(target.contents(of: target.locations.notifyRoot.appendingPathComponent("sources/demo.json.restored-invalid")), "unreadable current")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: target.locations.bundleRoot, includingPropertiesForKeys: nil))
        var previous: [String] = []
        for case let url as URL in enumerator where url.path.contains("/restored-files-") {
            if let value = target.contents(of: url) { previous.append(value) }
        }
        XCTAssertTrue(previous.contains("previous"))
        XCTAssertTrue(previous.contains("previous source"))
    }

    func testFinderMetadataIsSkippedButAnyOtherHiddenEntryIsReported() async throws {
        let source = try profile()
        try source.write("logo", to: source.locations.notifyRoot.appendingPathComponent("logos/a.png"))
        try source.write("finder", to: source.locations.notifyRoot.appendingPathComponent("logos/.DS_Store"))
        let url = archive(in: source)
        let key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment())
            .createArchive(at: url, key: key, sections: [.workspace])
        let paths = Set(try manifest(of: url, key: key).entries.map(\.path))
        XCTAssertTrue(paths.contains("workspace/notify/logos/a.png"))
        XCTAssertFalse(paths.contains { $0.contains("DS_Store") })

        // Anything else hidden is unknown data, and unknown data is never
        // dropped from a backup that reports success.
        try source.write("secret", to: source.locations.notifyRoot.appendingPathComponent(".env"))
        do {
            _ = try await ArtifactBackupEngine(environment: source.environment())
                .createArchive(at: archive(in: source), key: key, sections: [.workspace])
            XCTFail("expected an explicit failure")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError, .unsupportedFile("Notifications/.env"))
        }
    }

    func testMoreThan4096RetainedRecordingFilesRoundTrip() async throws {
        let source = try profile(), target = try profile()
        let meetings = try MeetingsStore(rootDirectory: source.locations.meetingsCatalog)
        openMeetingStores.append(meetings)
        let id = UUID().uuidString
        let count = 5220
        for index in 0..<count {
            try source.write("retained-\(index)", to: source.locations.meetingsStaging
                .appendingPathComponent("\(id)/chunk-\(index).wav"))
        }
        let url = archive(in: source), key = ArtifactBackupTestKeys.make()
        let engine = ArtifactBackupEngine(environment: source.environment(meetings: meetings))
        let summary = try await engine.createArchive(at: url, key: key, sections: [.meetings])
        XCTAssertGreaterThanOrEqual(summary.fileCount, count)
        _ = try await engine.inspectArchive(at: url, key: key)
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: url, key: key, sections: [.meetings])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        let restored = target.locations.meetingsStaging.appendingPathComponent(id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: restored.path).count, count)
        XCTAssertEqual(target.contents(of: restored.appendingPathComponent("chunk-5219.wav")), "retained-5219")
    }

    func testOversizedOwnedFileFailsInsteadOfBeingSkipped() async throws {
        let source = try profile()
        try source.write(Data(repeating: 1, count: 9 * 1024 * 1024),
                         to: source.locations.notifyRoot.appendingPathComponent("workers/huge.bin"))
        do {
            _ = try await ArtifactBackupEngine(environment: source.environment())
                .createArchive(at: archive(in: source), key: ArtifactBackupTestKeys.make(),
                               sections: [.workspace])
            XCTFail("expected a failure rather than a silent omission")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError, .tooLarge)
        }
    }

    func testSymlinkInsideAnOwnedRootFailsTheBackup() async throws {
        let source = try profile()
        try source.write("real", to: source.locations.notifyRoot.appendingPathComponent("logos/real.png"))
        let link = source.locations.notifyRoot.appendingPathComponent("logos/link.png")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
        do {
            _ = try await ArtifactBackupEngine(environment: source.environment())
                .createArchive(at: archive(in: source), key: ArtifactBackupTestKeys.make(),
                               sections: [.workspace])
            XCTFail("expected an unsafe-content failure")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError, .unsupportedFile("Notifications/logos/link.png"))
        }
    }

    func testSymlinkedOwnedRootFailsTheBackup() async throws {
        let source = try profile()
        let elsewhere = source.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try source.write("decoy", to: elsewhere.appendingPathComponent("servers.json"))
        try FileManager.default.createDirectory(at: source.locations.bundleRoot,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: source.locations.monitorRoot.path,
                                                   withDestinationPath: elsewhere.path)
        do {
            _ = try await ArtifactBackupEngine(environment: source.environment())
                .createArchive(at: archive(in: source), key: ArtifactBackupTestKeys.make(),
                               sections: [.workspace])
            XCTFail("expected an unsafe-content failure")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError, .unsupportedFile("Monitor"))
        }
    }

    func testUnownedProgramsAndMonitorCredentialsAreWarnedRatherThanClaimed() async throws {
        let source = try profile()
        let script = NotifyScript(id: "demo", name: "Demo", command: ["/usr/bin/python3", "/Users/me/own.py"],
                                  enabled: true)
        try source.write(try JSONEncoder().encode(script),
                         to: source.locations.notifyRoot.appendingPathComponent("sources/demo.json"))
        try source.write("#!/bin/sh\nexit 0",
                         to: source.locations.notifyRoot.appendingPathComponent("workers/local.sh"))
        try source.write(#"{"refreshSeconds":15,"servers":[{"id":"a","name":"A","group":"g","sshTarget":"user@host"}]}"#,
                         to: source.locations.monitorRoot.appendingPathComponent("servers.json"))
        let url = archive(in: source)
        let key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment())
            .createArchive(at: url, key: key, sections: [.workspace])
        let warnings = try await ArtifactBackupEngine(environment: source.environment())
            .inspectArchive(at: url, key: key).warnings
        let joined = warnings.joined(separator: " | ")
        XCTAssertTrue(warnings.contains { $0.contains("outside Whytap") }, joined)
        XCTAssertTrue(warnings.contains { $0.contains("SSH keys") }, joined)
        XCTAssertTrue(warnings.contains { $0.contains("switched off") }, joined)
        XCTAssertTrue(warnings.contains { $0.contains("read-only") }, joined)
    }

    // MARK: - Retained audio

    func testRawOrphanAudioWithoutAFinalizeRecordStillTravels() async throws {
        let source = try profile()
        let meetings = try MeetingsStore(rootDirectory: source.locations.meetingsCatalog)
        openMeetingStores.append(meetings)
        let orphan = UUID()
        let directory = source.locations.meetingsStaging
            .appendingPathComponent(orphan.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try source.write(Data(repeating: 7, count: 2048),
                         to: directory.appendingPathComponent("chunk-000.wav"))
        try source.write(Data(repeating: 8, count: 64),
                         to: directory.appendingPathComponent("chunk-000.sha256"))
        // A chunk still being written is not persisted audio yet.
        try source.write(Data(repeating: 9, count: 32),
                         to: directory.appendingPathComponent("chunk-001.wav.tmp"))
        // One a crash abandoned long ago exists nowhere else, so it travels.
        let abandoned = directory.appendingPathComponent("chunk-002.wav.tmp")
        try source.write(Data(repeating: 10, count: 16), to: abandoned)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: abandoned.path)
        let url = archive(in: source)
        let key = ArtifactBackupTestKeys.make()
        let summary = try await ArtifactBackupEngine(environment: source.environment(meetings: meetings))
            .createArchive(at: url, key: key, sections: [.meetings])
        XCTAssertTrue(summary.sections.contains(.meetings))
        let paths = Set(try manifest(of: url, key: key).entries.map(\.path))
        XCTAssertTrue(paths.contains("meetings/staged/\(orphan.uuidString)/chunk-000.wav"))
        XCTAssertTrue(paths.contains("meetings/staged/\(orphan.uuidString)/chunk-000.sha256"))
        XCTAssertFalse(paths.contains("meetings/staged/\(orphan.uuidString)/chunk-001.wav.tmp"),
                       "a chunk still being written cannot be captured coherently")
        XCTAssertTrue(paths.contains("meetings/staged/\(orphan.uuidString)/chunk-002.wav.tmp"),
                      "an abandoned chunk is the only copy of those bytes")

        let preview = try await ArtifactBackupEngine(environment: source.environment(meetings: meetings))
            .inspectArchive(at: url, key: key)
        XCTAssertTrue(preview.warnings.contains { $0.contains("still being written") },
                      preview.warnings.joined(separator: " | "))

        let target = try profile()
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: url, key: key, sections: [.meetings])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(try Data(contentsOf: target.locations.meetingsStaging
            .appendingPathComponent(orphan.uuidString, isDirectory: true)
            .appendingPathComponent("chunk-000.wav")).count, 2048)
    }

    func testStrayFileInTheRecordingRootFailsRatherThanDisappearing() async throws {
        let source = try profile()
        let meetings = try MeetingsStore(rootDirectory: source.locations.meetingsCatalog)
        openMeetingStores.append(meetings)
        try source.write("who knows", to: source.locations.meetingsStaging
            .appendingPathComponent("stray.bin"))
        do {
            _ = try await ArtifactBackupEngine(environment: source.environment(meetings: meetings))
                .createArchive(at: archive(in: source), key: ArtifactBackupTestKeys.make(),
                               sections: [.meetings])
            XCTFail("expected an explicit failure")
        } catch {
            guard case .invalidContent = (error as? ArtifactBackupError) else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: - Case key rotation

    func testStagedCaseCiphertextIsVerifiedAgainstTheExportedKey() async throws {
        let source = try profile()
        let originalKey = SymmetricKey(size: .bits256)
        try CaseVaultStore(fileURL: source.locations.caseVault)
            .save(CaseVaultPayload(), using: originalKey)
        // The exported key no longer matches the vault on disk: a reset or key
        // rotation between the pre-check and the copy must not produce a
        // successful backup nobody can open.
        let rotated = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let request = ArtifactBackupStageRequest(
            sections: [.caseVault], locations: source.locations,
            inline: [ArtifactInlinePayload(path: "case/vault.key", section: .caseVault, data: rotated)],
            includeCaseVaultFile: true, caseVaultKey: rotated, meetings: nil, history: nil)
        do {
            _ = try await ArtifactBackupStager().stage(request)
            XCTFail("expected caseUnreadable")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError, .caseUnreadable)
        }
    }

    // MARK: - Content validation before anything is touched

    func testFutureInlineSchemaIsRefusedBeforeArming() async throws {
        let target = try profile()
        let key = ArtifactBackupTestKeys.make()
        let url = archive(in: target)
        _ = try ArtifactBackupTestArchive.make(at: url, key: key, entries: [
            (path: "settings/preferences.json", section: .settings,
             data: try ArtifactBackupTestArchive.settingsPayload(
                schema: ArtifactSettingsPayload.currentSchema + 1))
        ])
        let engine = ArtifactBackupEngine(environment: target.environment())
        do {
            try await engine.stageRestore(from: url, key: key, sections: [.settings])
            XCTFail("expected needsNewerApp")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError, .needsNewerApp)
        }
        XCTAssertFalse(engine.hasPendingRestore)
    }

    func testUnknownPreferenceKeyIsRefusedBeforeArming() async throws {
        let target = try profile()
        let key = ArtifactBackupTestKeys.make()
        let url = archive(in: target)
        _ = try ArtifactBackupTestArchive.make(at: url, key: key, entries: [
            (path: "settings/preferences.json", section: .settings,
             data: try ArtifactBackupTestArchive.settingsPayload(
                values: ["not.an.allowlisted.key": .string("x")]))
        ])
        let engine = ArtifactBackupEngine(environment: target.environment())
        do {
            try await engine.stageRestore(from: url, key: key, sections: [.settings])
            XCTFail("expected invalidContent")
        } catch {
            guard case .invalidContent = (error as? ArtifactBackupError) else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertFalse(engine.hasPendingRestore)
    }

    func testCredentialPayloadOutsideTheAllowlistIsRefused() async throws {
        let target = try profile()
        let key = ArtifactBackupTestKeys.make()
        let url = archive(in: target)
        _ = try ArtifactBackupTestArchive.make(at: url, key: key, entries: [
            (path: "credentials/providers.json", section: .credentials,
             data: try ArtifactBackupTestArchive.credentialsPayload(
                accounts: ["some.other.account": "value"]))
        ])
        let engine = ArtifactBackupEngine(environment: target.environment())
        do {
            try await engine.stageRestore(from: url, key: key, sections: [.credentials])
            XCTFail("expected invalidContent")
        } catch {
            guard case .invalidContent = (error as? ArtifactBackupError) else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testDamagedDatabaseIsRefusedEvenWithValidDigests() async throws {
        let target = try profile()
        let key = ArtifactBackupTestKeys.make()
        let url = archive(in: target)
        _ = try ArtifactBackupTestArchive.make(at: url, key: key, entries: [
            (path: "history/db/history.sqlite", section: .history,
             data: Data("SQLite format 3\u{0}this is not a database".utf8))
        ])
        let engine = ArtifactBackupEngine(environment: target.environment())
        do {
            try await engine.stageRestore(from: url, key: key, sections: [.history])
            XCTFail("expected invalidContent")
        } catch {
            guard case .invalidContent = (error as? ArtifactBackupError) else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertFalse(engine.hasPendingRestore)
        XCTAssertFalse(target.exists(target.locations.historyDatabase))
    }

    func testMissingRequiredEntryIsRefusedBeforeArming() async throws {
        let target = try profile()
        let key = ArtifactBackupTestKeys.make()
        let url = archive(in: target)
        _ = try ArtifactBackupTestArchive.make(at: url, key: key, entries: [
            (path: "case/vault.enc", section: .caseVault, data: Data("x".utf8))
        ])
        let engine = ArtifactBackupEngine(environment: target.environment())
        do {
            try await engine.stageRestore(from: url, key: key, sections: [.caseVault])
            XCTFail("expected incompleteArchive")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError, .incompleteArchive("case/vault.key"))
        }
    }

    func testReadyMeetingWithoutItsNoteEntryIsRefusedBeforeArming() async throws {
        let source = try profile()
        let meetings = try MeetingsStore(rootDirectory: source.locations.meetingsCatalog)
        openMeetingStores.append(meetings)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await meetings.insert(
            meta: MeetingMetaWithLocalState(id: id, startedAt: now, endedAt: now, durationSeconds: 1,
                                            title: "Ready", syncStatus: .new, serverVersion: 1,
                                            createdAt: now),
            markdown: "# note")
        let scratch = source.root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let exported = try await meetings.exportArtifactGeneration(into: scratch)
        let database = try XCTUnwrap(exported.first { $0.relativePath.hasSuffix("meetings.sqlite") })

        let key = ArtifactBackupTestKeys.make()
        let url = archive(in: source)
        // The catalog travels without the note the row requires.
        _ = try ArtifactBackupTestArchive.make(at: url, key: key, entries: [
            (path: "meetings/db/meetings.sqlite", section: .meetings,
             data: try Data(contentsOf: database.url))
        ])
        let target = try profile()
        let engine = ArtifactBackupEngine(environment: target.environment())
        do {
            try await engine.stageRestore(from: url, key: key, sections: [.meetings])
            XCTFail("expected incompleteArchive")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError,
                           .incompleteArchive("meetings/notes/\(id.uuidString).md"))
        }
        XCTAssertFalse(engine.hasPendingRestore)
    }

    func testUnreadableNotifyConfigurationKeepsItsBytesInertly() async throws {
        let target = try profile()
        let key = ArtifactBackupTestKeys.make()
        let url = archive(in: target)
        let bytes = Data(#"{"future":"shape","id":"demo"}"#.utf8)
        _ = try ArtifactBackupTestArchive.make(at: url, key: key, entries: [
            (path: "workspace/notify/sources/demo.json", section: .workspace, data: bytes)
        ])
        let environment = target.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        let preview = try await engine.inspectArchive(at: url, key: key)
        XCTAssertTrue(preview.warnings.contains { $0.contains("cannot be read") },
                      preview.warnings.joined(separator: " | "))
        try await engine.stageRestore(from: url, key: key, sections: [.workspace])
        let outcome = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(outcome?.state, .applied)
        let sources = target.locations.notifyRoot.appendingPathComponent("sources", isDirectory: true)
        XCTAssertFalse(target.exists(sources.appendingPathComponent("demo.json")),
                       "an unreadable configuration must not become live")
        XCTAssertEqual(try Data(contentsOf: sources.appendingPathComponent("demo.json.restored-invalid")),
                       bytes)
    }

    /// Schema 2 payloads restore one Settings block. Everything the user
    /// changed in another block between arming and the relaunch must survive.
    func testBlockScopedSettingsPayloadOnlyRewritesItsOwnBlock() async throws {
        let target = try profile()
        target.defaults.set("soniox", forKey: "sidekey.models.byokProvider")
        target.defaults.set(false, forKey: "sidekey.preferences.brightnessKeys")
        let key = ArtifactBackupTestKeys.make()
        let url = archive(in: target)
        let payload = ArtifactSettingsPayload(
            values: ["sidekey.preferences.brightnessKeys": .bool(true)], selectedSections: [.hotkeys])
        _ = try ArtifactBackupTestArchive.make(at: url, key: key, entries: [
            (path: "settings/preferences.json", section: .settings,
             data: try JSONEncoder.artifactBackup.encode(payload))
        ])
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: url, key: key, sections: [.settings])
        // An edit in another block lands after the restore was parked.
        target.defaults.set("deepgram", forKey: "sidekey.models.byokProvider")
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(target.defaults.object(forKey: "sidekey.preferences.brightnessKeys") as? Bool, true)
        XCTAssertEqual(target.defaults.string(forKey: "sidekey.models.byokProvider"), "deepgram")
    }

    func testBlockScopedPayloadCarryingAnotherBlocksKeyIsRefused() async throws {
        let target = try profile()
        let key = ArtifactBackupTestKeys.make()
        let url = archive(in: target)
        let payload = ArtifactSettingsPayload(
            values: ["sidekey.models.byokProvider": .string("soniox")], selectedSections: [.hotkeys])
        _ = try ArtifactBackupTestArchive.make(at: url, key: key, entries: [
            (path: "settings/preferences.json", section: .settings,
             data: try JSONEncoder.artifactBackup.encode(payload))
        ])
        let engine = ArtifactBackupEngine(environment: target.environment())
        do {
            try await engine.stageRestore(from: url, key: key, sections: [.settings])
            XCTFail("expected invalidContent")
        } catch {
            guard case .invalidContent = (error as? ArtifactBackupError) else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertFalse(engine.hasPendingRestore)
    }

    func testCaseInsensitiveDuplicateTargetsAreRefused() async throws {
        let target = try profile()
        let key = ArtifactBackupTestKeys.make()
        let url = archive(in: target)
        let id = UUID().uuidString
        _ = try ArtifactBackupTestArchive.make(at: url, key: key, entries: [
            (path: "workspace/notify/logos/Logo.png", section: .workspace, data: Data("a".utf8)),
            (path: "workspace/notify/logos/logo.png", section: .workspace, data: Data("b".utf8)),
            (path: "meetings/notes/\(id).md", section: .meetings, data: Data("c".utf8))
        ])
        let engine = ArtifactBackupEngine(environment: target.environment())
        do {
            try await engine.stageRestore(from: url, key: key, sections: [.workspace])
            XCTFail("expected unsafeContent")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError, .unsafeContent)
        }
    }
}
