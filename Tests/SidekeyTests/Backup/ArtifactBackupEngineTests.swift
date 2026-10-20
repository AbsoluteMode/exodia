import CryptoKit
import XCTest
@testable import Sidekey

/// End-to-end proof on synthetic profiles: a complete backup of settings,
/// provider keys, Case, meetings (including staged recordings), history with
/// its image bytes and the Monitor/Notify/agent workspace, restored into a
/// clean profile with no real Keychain and no user data.
@MainActor
final class ArtifactBackupEngineTests: XCTestCase {
    private var profiles: [ArtifactBackupTestProfile] = []
    private var openMeetingStores: [MeetingsStore] = []

    override func tearDown() async throws {
        for store in openMeetingStores { await store.close() }
        openMeetingStores.removeAll()
        profiles.forEach { $0.tearDown() }
        profiles.removeAll()
    }

    // MARK: - Fixtures

    private struct Source {
        var profile: ArtifactBackupTestProfile
        var environment: ArtifactBackupEnvironment
        var caseKey: SymmetricKey
        var meetingID: UUID
        var imageUUID: UUID
        var stagedRecordingID: UUID
        var imageBytes: Data
        var meetings: MeetingsStore
        var history: SQLiteHistoryStore
    }

    private let sonioxAccount = "byok.soniox.api_key"
    private let routerAccount = "byok.openrouter.llm_api_key"

    private func makeSource() async throws -> Source {
        let caseKey = SymmetricKey(size: .bits256)
        var profile = try ArtifactBackupTestProfile(caseKey: caseKey)
        profiles.append(profile)

        profile.defaults.set("soniox", forKey: "sidekey.models.byokProvider")
        profile.defaults.set(["Whytap", "Максим"], forKey: "sidekey.preferences.vocabularyTerms")
        profile.defaults.set(true, forKey: "sidekey.privacy.screenshotProtectionEnabled")

        profile.addCredential(sonioxAccount, "synthetic-soniox-key")
        profile.addCredential(routerAccount, "synthetic-openrouter-key")

        // Case: one secret, its value and a group.
        let secretID = UUID()
        let serversID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = CaseVaultPayload(
            projects: [.general(now: now),
                       CaseProject(id: serversID, name: "Servers", description: "", createdAt: now, updatedAt: now)],
            secrets: [CaseSecret(id: secretID, name: "Netcup root", projectID: serversID, description: "",
                                 copyCount: 2, lastCopiedAt: now, createdAt: now, updatedAt: now)],
            values: [CaseSecretValue(secretID: secretID, value: "synthetic-case-secret")])
        try CaseVaultStore(fileURL: profile.locations.caseVault).save(payload, using: caseKey)

        // Meetings: a row with a note and a transcript sidecar.
        let meetings = try MeetingsStore(rootDirectory: profile.locations.meetingsCatalog)
        openMeetingStores.append(meetings)
        let meetingID = UUID()
        try await meetings.insert(
            meta: MeetingMetaWithLocalState(id: meetingID, startedAt: now, endedAt: now.addingTimeInterval(600),
                                            durationSeconds: 600, title: "Synthetic standup",
                                            syncStatus: .new, serverVersion: 1, createdAt: now),
            markdown: "# Synthetic standup\n\nSynthetic note body.",
            transcript: [TranscriptSegment(speaker: "A", start: 0, end: 2, text: "synthetic transcript")])

        // A finalised recording whose processing failed: staged audio is the
        // only copy, so it has to travel with the backup.
        let stagedID = UUID()
        let stagedDirectory = profile.locations.meetingsStaging
            .appendingPathComponent(stagedID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096)
            .write(to: stagedDirectory.appendingPathComponent("chunk-000.wav"))
        try MeetingFinalizeManifestStore().write(
            MeetingFinalizeManifest(recorderMeetingId: stagedID, startedAt: now, endedAt: now,
                                    durationSeconds: 60, language: "ru",
                                    chunkFileNames: ["chunk-000.wav"], isFinal: true),
            to: stagedDirectory)
        // Remote provider job state: must stay on this Mac.
        try Data("{\"fileID\":\"synthetic-remote-job\"}".utf8)
            .write(to: stagedDirectory.appendingPathComponent("soniox-transcription.json"))

        // A recording still being written has no manifest and is skipped.
        let liveDirectory = profile.locations.meetingsStaging
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 128).write(to: liveDirectory.appendingPathComponent("chunk-000.wav.tmp"))

        // History: text, an external file link and a managed image.
        try FileManager.default.createDirectory(
            at: profile.locations.historyDatabase.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let history = try SQLiteHistoryStore(path: profile.locations.historyDatabase.path)
        _ = try history.insertClipboardTextEntry(createdAt: now, text: "synthetic clipboard text")
        _ = try history.insertClipboardFileURLsEntry(
            createdAt: now, urls: [URL(fileURLWithPath: "/Users/synthetic/Documents/original.pdf")])
        let imageUUID = UUID()
        let imageBytes = Data(repeating: 0x7A, count: 2048)
        _ = try history.insertClipboardImageEntry(
            createdAt: now, uuid: imageUUID, imageData: imageBytes, imageExtension: "png",
            thumbnailData: Data(repeating: 0x7B, count: 64),
            assetsDirectory: profile.locations.historyAssets)

        // Workspace: Monitor, Notify and the agent memory.
        try profile.write(#"{"refreshSeconds":15,"servers":[{"id":"netcup","name":"Netcup","group":"prod","sshTarget":"terra@example.net"}]}"#,
                          to: profile.locations.monitorRoot.appendingPathComponent("servers.json"))
        try profile.write(#"{"id":"mine","title":"Mine","widgets":[{"id":"w1","kind":"metric","title":"CPU","value":"12"}]}"#,
                          to: profile.locations.monitorRoot
                            .appendingPathComponent("dashboards", isDirectory: true)
                            .appendingPathComponent("mine.json"))
        let script = NotifyScript(id: "demo", name: "Demo source", command: ["/bin/echo", "hi"],
                                  enabled: true, intervalSeconds: 60)
        try profile.write(try JSONEncoder().encode(script),
                          to: profile.locations.notifyRoot
                            .appendingPathComponent("sources", isDirectory: true)
                            .appendingPathComponent("demo.json"))
        try profile.write(Data(repeating: 0x89, count: 256),
                          to: profile.locations.notifyRoot
                            .appendingPathComponent("logos", isDirectory: true)
                            .appendingPathComponent("demo.png"))
        try profile.write("[]", to: profile.locations.notifyRoot.appendingPathComponent("history.json"))
        try profile.write("# Agent memory\nsynthetic instruction", to: profile.locations.agentMemory)
        XCTAssertTrue(PlannerStore(url: profile.locations.plannerArchive).saveTask(PlannerTask(title: "Synthetic task")))

        return Source(profile: profile, environment: profile.environment(meetings: meetings, history: history),
                      caseKey: caseKey, meetingID: meetingID, imageUUID: imageUUID,
                      stagedRecordingID: stagedID, imageBytes: imageBytes,
                      meetings: meetings, history: history)
    }

    private func makeTarget() throws -> ArtifactBackupTestProfile {
        var profile = try ArtifactBackupTestProfile()
        profiles.append(profile)
        // Observable stores for the accounts a restore writes.
        profile.addCredential(sonioxAccount, nil)
        profile.addCredential(routerAccount, nil)
        return profile
    }

    private func archiveURL(in profile: ArtifactBackupTestProfile) -> URL {
        profile.root.appendingPathComponent("backup-\(UUID().uuidString).exodiabackup")
    }

    // MARK: - Legacy paths

    /// The backup must read and write exactly where the stores do. These are
    /// the legacy locations the rename preserved; deriving any of them from
    /// the current bundle id would point a beta build at files the app never
    /// writes (history is prod-scoped) and silently back up nothing.
    func testProductionLocationsMatchEveryStoresOwnPath() {
        let locations = ArtifactBackupLocations.production
        XCTAssertEqual(locations.historyDatabase, HistoryStoreLocation.defaultURL)
        XCTAssertEqual(locations.historyAssets.standardizedFileURL,
                       HistoryStoreLocation.defaultAssetsDirectory.standardizedFileURL)
        XCTAssertEqual(locations.meetingsCatalog.standardizedFileURL,
                       MeetingsStore.defaultRootDirectory().standardizedFileURL)
        XCTAssertEqual(locations.caseVault, CaseVaultStore.defaultFileURL)
        XCTAssertEqual(locations.monitorRoot.standardizedFileURL, MonitorPaths.root.standardizedFileURL)
        XCTAssertEqual(locations.notifyRoot.standardizedFileURL, NotifyPaths.root.standardizedFileURL)
        XCTAssertEqual(locations.agentMemory.lastPathComponent, "AGENTS.md")
        XCTAssertTrue(locations.agentWorkspace.path.hasSuffix("/whytap/agent"), locations.agentWorkspace.path)
    }

    // MARK: - Complete round trip

    func testCompleteBackupRestoresIntoACleanProfileWithoutKeychain() async throws {
        let source = try await makeSource()
        let key = ArtifactBackupTestKeys.make()
        let archive = archiveURL(in: source.profile)
        let engine = ArtifactBackupEngine(environment: source.environment)
        let summary = try await engine.createArchive(at: archive, key: key)

        XCTAssertEqual(summary.sections, Set(ArtifactBackupSection.allCases))
        XCTAssertGreaterThan(summary.fileCount, 8)
        XCTAssertGreaterThan(summary.totalBytes, 4096)

        // Nothing readable leaks into the file, and the staging directory is gone.
        let bytes = try Data(contentsOf: archive)
        for secret in ["synthetic-soniox-key", "synthetic-case-secret", "synthetic standup",
                       "Максим", "synthetic instruction"] {
            XCTAssertNil(bytes.range(of: Data(secret.utf8)), secret)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: source.profile.locations.stagingWorkRoot.path), [])

        let preview = try await engine.inspectArchive(at: archive, key: key)
        XCTAssertEqual(preview.summary.sections, Set(ArtifactBackupSection.allCases))
        XCTAssertTrue(preview.warnings.contains { $0.contains("only link to your own files") },
                      preview.warnings.joined(separator: " | "))
        XCTAssertTrue(preview.warnings.contains { $0.contains("still being written") },
                      preview.warnings.joined(separator: " | "))

        let manifest = try ArtifactRestoreTransaction.validateArchive(at: archive, key: key)
        let paths = Set(manifest.entries.map(\.path))
        XCTAssertTrue(paths.contains("meetings/staged/\(source.stagedRecordingID.uuidString)/chunk-000.wav"))
        XCTAssertFalse(paths.contains { $0.contains("soniox-transcription") })
        XCTAssertFalse(paths.contains { $0.contains("original.pdf") })

        // Restore into an empty profile.
        let target = try makeTarget()
        let targetEnvironment = target.environment()
        let restoreEngine = ArtifactBackupEngine(environment: targetEnvironment)
        try await restoreEngine.stageRestore(from: archive, key: key,
                                             sections: Set(ArtifactBackupSection.allCases))
        XCTAssertTrue(restoreEngine.hasPendingRestore)
        // Nothing is applied while the runtime is open.
        XCTAssertFalse(target.exists(target.locations.meetingsCatalog
            .appendingPathComponent("\(source.meetingID.uuidString).md")))

        let outcome = try ArtifactBackupEngine.applyPendingRestore(environment: targetEnvironment)
        XCTAssertEqual(outcome?.state, .applied)

        // Settings and provider keys.
        XCTAssertEqual(target.defaults.string(forKey: "sidekey.models.byokProvider"), "soniox")
        XCTAssertEqual(target.defaults.stringArray(forKey: "sidekey.preferences.vocabularyTerms"),
                       ["Whytap", "Максим"])
        XCTAssertTrue(target.defaults.bool(forKey: "sidekey.privacy.screenshotProtectionEnabled"))
        XCTAssertEqual(target.credentialStores[sonioxAccount]?.value, "synthetic-soniox-key")
        XCTAssertEqual(target.credentialStores[routerAccount]?.value, "synthetic-openrouter-key")

        // Case is readable with the target's OWN key, not the source's.
        let localKey = try XCTUnwrap(target.caseKeys.existingVaultKey())
        XCTAssertNotEqual(localKey.withUnsafeBytes { Data($0) },
                          source.caseKey.withUnsafeBytes { Data($0) })
        let restoredCase = try CaseVaultStore(fileURL: target.locations.caseVault).load(using: localKey)
        XCTAssertEqual(restoredCase.secrets.map(\.name), ["Netcup root"])
        XCTAssertEqual(restoredCase.values.first?.value, "synthetic-case-secret")
        XCTAssertEqual(restoredCase.projects.first { $0.id != CaseProject.generalID }?.name, "Servers")

        // Meetings: row, note, transcript and the staged recording.
        let restoredMeetings = try MeetingsStore(rootDirectory: target.locations.meetingsCatalog)
        openMeetingStores.append(restoredMeetings)
        let rows = try await restoredMeetings.list()
        XCTAssertEqual(rows.map(\.id), [source.meetingID])
        let restoredMarkdown = try await restoredMeetings.markdown(id: source.meetingID)
        XCTAssertEqual(restoredMarkdown, "# Synthetic standup\n\nSynthetic note body.")
        let restoredTranscript = try await restoredMeetings.transcript(id: source.meetingID)
        XCTAssertEqual(restoredTranscript?.first?.text, "synthetic transcript")
        let stagedDirectory = target.locations.meetingsStaging
            .appendingPathComponent(source.stagedRecordingID.uuidString, isDirectory: true)
        XCTAssertTrue(target.exists(stagedDirectory.appendingPathComponent("chunk-000.wav")))
        // The finalize record is parked: nothing re-dispatches another Mac's
        // recording on its own, and the audio is still recoverable.
        XCTAssertFalse(target.exists(stagedDirectory.appendingPathComponent("manifest.json")))
        XCTAssertTrue(target.exists(stagedDirectory
            .appendingPathComponent("manifest.json.restored-inactive")))
        XCTAssertFalse(target.exists(stagedDirectory.appendingPathComponent("soniox-transcription.json")))

        // History rows plus the managed image bytes.
        let restoredHistory = try SQLiteHistoryStore(path: target.locations.historyDatabase.path)
        XCTAssertEqual(try restoredHistory.latestClipboardEntries(limit: 20).count, 3)
        XCTAssertEqual(try Data(contentsOf: target.locations.historyAssets
            .appendingPathComponent("\(source.imageUUID.uuidString).png")), source.imageBytes)

        // Workspace: dashboards restored, executable configuration inert.
        XCTAssertTrue(target.exists(target.locations.monitorRoot
            .appendingPathComponent("dashboards", isDirectory: true).appendingPathComponent("mine.json")))
        XCTAssertFalse(target.exists(target.locations.monitorRoot.appendingPathComponent("servers.json")))
        XCTAssertTrue(target.exists(target.locations.monitorRoot
            .appendingPathComponent("servers.json.restored-inactive")))
        let restoredScript = try JSONDecoder().decode(NotifyScript.self, from: Data(contentsOf:
            target.locations.notifyRoot.appendingPathComponent("sources", isDirectory: true)
                .appendingPathComponent("demo.json")))
        XCTAssertFalse(restoredScript.enabled)
        XCTAssertEqual(restoredScript.command, ["/bin/echo", "hi"])
        XCTAssertTrue(target.exists(target.locations.notifyRoot
            .appendingPathComponent("logos", isDirectory: true).appendingPathComponent("demo.png")))
        XCTAssertEqual(target.contents(of: target.locations.agentMemory),
                       "# Agent memory\nsynthetic instruction")

        // The transaction is finished: no archive copy, no key, a durable outcome.
        XCTAssertFalse(target.exists(target.locations.pendingRestoreRoot
            .appendingPathComponent("plan.json")))
        XCTAssertFalse(target.exists(target.locations.pendingRestoreRoot
            .appendingPathComponent("pending.exodiabackup")))
        XCTAssertNil(target.pendingKeyStore.value)
        XCTAssertEqual(ArtifactBackupEngine.lastRestoreOutcome(locations: target.locations)?.state, .applied)
    }

    // MARK: - Selections

    func testRestoringOneSectionLeavesEverythingElseAlone() async throws {
        let source = try await makeSource()
        let key = ArtifactBackupTestKeys.make()
        let archive = archiveURL(in: source.profile)
        _ = try await ArtifactBackupEngine(environment: source.environment)
            .createArchive(at: archive, key: key)

        let target = try makeTarget()
        try target.write("# Local memory", to: target.locations.agentMemory)
        let environment = target.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        try await engine.stageRestore(from: archive, key: key, sections: [.settings])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)

        XCTAssertEqual(target.defaults.string(forKey: "sidekey.models.byokProvider"), "soniox")
        XCTAssertEqual(target.contents(of: target.locations.agentMemory), "# Local memory")
        XCTAssertFalse(target.exists(target.locations.meetingsCatalog
            .appendingPathComponent("meetings.sqlite")))
        XCTAssertFalse(target.exists(target.locations.historyDatabase))
        XCTAssertNil(target.credentialStores[sonioxAccount]?.value)
        XCTAssertFalse(target.exists(target.locations.caseVault))
    }

    // MARK: - Case merge

    func test_v1_case_archive_restores_into_current_vault() async throws {
        let source = try await makeSource()
        // Replace the source vault with a schema-1 file: a group, a grouped
        // key, an ungrouped key and a key whose name starts with a digit.
        let groupID = UUID(), groupedID = UUID(), looseID = UUID(), digitID = UUID()
        let stamp = Date(timeIntervalSince1970: 1_500_000_000)
        let v1 = try CaseVaultMigrationTests.v1Plaintext(
            secrets: [(groupedID, "SSH_PASS", groupID), (looseID, "LOOSE_KEY", nil), (digitID, "1PASSWORD", nil)],
            groups: [(groupID, "servers", [groupedID])], at: stamp)
        try CaseVaultMigrationTests.writeSealedVault(v1, key: source.caseKey, to: source.profile.locations.caseVault)

        let key = ArtifactBackupTestKeys.make()
        let archive = archiveURL(in: source.profile)
        _ = try await ArtifactBackupEngine(environment: source.environment).createArchive(at: archive, key: key)

        let localKey = SymmetricKey(size: .bits256)
        var target = try ArtifactBackupTestProfile(caseKey: localKey)
        profiles.append(target)
        target.addCredential(sonioxAccount, nil)
        let localID = UUID()
        let localProject = CaseProject(id: UUID(), name: "Local project", description: "mine",
                                       createdAt: stamp, updatedAt: stamp)
        try CaseVaultStore(fileURL: target.locations.caseVault).save(
            CaseVaultPayload(
                projects: [.general(now: stamp), localProject],
                secrets: [CaseSecret(id: localID, name: "LOCAL_ONLY", projectID: localProject.id, description: "",
                                     copyCount: 0, lastCopiedAt: nil, createdAt: stamp, updatedAt: stamp)],
                values: [CaseSecretValue(secretID: localID, value: "local-secret-value")],
                timedApprovalMinutes: 45),
            using: localKey)

        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: archive, key: key, sections: [.caseVault])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)

        let merged = try CaseVaultStore(fileURL: target.locations.caseVault).load(using: localKey)
        XCTAssertEqual(merged.schemaVersion, CaseVaultPayload.currentSchemaVersion)
        XCTAssertTrue(Set(merged.secrets.map(\.name)).isSuperset(of: ["LOCAL_ONLY", "SSH_PASS", "LOOSE_KEY", "_1PASSWORD"]))
        let projectIDs = Set(merged.projects.map(\.id))
        XCTAssertTrue(merged.secrets.allSatisfy { projectIDs.contains($0.projectID) })
        XCTAssertEqual(merged.projects.first?.id, CaseProject.generalID)
        XCTAssertEqual(merged.secrets.first { $0.id == groupedID }?.projectID, groupID)
        XCTAssertEqual(merged.secrets.first { $0.id == looseID }?.projectID, CaseProject.generalID)
        XCTAssertEqual(merged.secrets.first { $0.id == localID }?.projectID, localProject.id)
        XCTAssertEqual(merged.value(for: digitID), "value-of-1PASSWORD")
        XCTAssertEqual(merged.value(for: localID), "local-secret-value")
        XCTAssertEqual(merged.timedApprovalMinutes, 45)
    }

    func testCaseRestoreMergesAndKeepsThisMacsOtherSecrets() async throws {
        let source = try await makeSource()
        let imported = CaseAppRegistration(id: UUID(), displayName: "Synthetic scoped agent",
            identity: .executablePath("/fixture/scoped-agent"), defaultMode: .bypass, projectModes: [:],
            createdAt: Date(timeIntervalSinceReferenceDate: 0), allowedProjectIDs: [CaseProject.generalID])
        var paused = imported
        paused.id = UUID()
        paused.identity = .executablePath("/fixture/paused-agent")
        paused.allowedProjectIDs = []
        let sourceStore = CaseVaultStore(fileURL: source.profile.locations.caseVault)
        var sourcePayload = try sourceStore.load(using: source.caseKey)
        sourcePayload.apps = [imported, paused]
        try sourceStore.save(sourcePayload, using: source.caseKey)
        let key = ArtifactBackupTestKeys.make()
        let archive = archiveURL(in: source.profile)
        _ = try await ArtifactBackupEngine(environment: source.environment)
            .createArchive(at: archive, key: key)

        let localKey = SymmetricKey(size: .bits256)
        var target = try ArtifactBackupTestProfile(caseKey: localKey)
        profiles.append(target)
        target.addCredential(sonioxAccount, nil)
        let localID = UUID()
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try CaseVaultStore(fileURL: target.locations.caseVault).save(
            CaseVaultPayload(
                secrets: [CaseSecret(id: localID, name: "Local only", projectID: CaseProject.generalID,
                                     description: "", copyCount: 0,
                                     lastCopiedAt: nil, createdAt: stamp, updatedAt: stamp)],
                values: [CaseSecretValue(secretID: localID, value: "local-secret-value")]),
            using: localKey)

        let environment = target.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        try await engine.stageRestore(from: archive, key: key, sections: [.caseVault])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)

        let merged = try CaseVaultStore(fileURL: target.locations.caseVault).load(using: localKey)
        XCTAssertEqual(Set(merged.secrets.map(\.name)), ["Local only", "Netcup root"])
        XCTAssertEqual(merged.value(for: localID), "local-secret-value")
        XCTAssertTrue(merged.values.contains { $0.value == "synthetic-case-secret" })
        XCTAssertEqual(merged.apps.first { $0.id == imported.id }?.allowedProjectIDs, [CaseProject.generalID])
        XCTAssertEqual(merged.apps.first { $0.id == paused.id }?.allowedProjectIDs, [], "restore must not turn no access into all projects")
        // Still this Mac's own key: the source key must not open it.
        XCTAssertThrowsError(try CaseVaultStore(fileURL: target.locations.caseVault)
            .load(using: source.caseKey))
    }

    // MARK: - Fail closed

    func testMissingHistoryImageFailsTheWholeBackup() async throws {
        let source = try await makeSource()
        let asset = source.profile.locations.historyAssets
            .appendingPathComponent("\(source.imageUUID.uuidString).png")
        try FileManager.default.removeItem(at: asset)
        let archive = archiveURL(in: source.profile)
        do {
            _ = try await ArtifactBackupEngine(environment: source.environment)
                .createArchive(at: archive, key: ArtifactBackupTestKeys.make())
            XCTFail("expected a required-file failure")
        } catch let error as ArtifactBackupError {
            guard case .requiredFileMissing(let name) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(name.hasPrefix(source.imageUUID.uuidString))
        }
        XCTAssertFalse(source.profile.exists(archive))
    }

    func testExistingCaseVaultWithoutItsKeyIsNeverSilentlyOmitted() async throws {
        let caseKey = SymmetricKey(size: .bits256)
        var profile = try ArtifactBackupTestProfile(caseKey: caseKey)
        profiles.append(profile)
        profile.addCredential(sonioxAccount, "synthetic-key")
        try CaseVaultStore(fileURL: profile.locations.caseVault)
            .save(CaseVaultPayload(), using: caseKey)
        // The Mac has the vault file but can no longer read its key.
        let keyless = StubCaseVaultKeys(stored: nil)
        var environment = profile.environment()
        environment.caseVaultKeys = keyless
        let archive = archiveURL(in: profile)
        do {
            _ = try await ArtifactBackupEngine(environment: environment)
                .createArchive(at: archive, key: ArtifactBackupTestKeys.make(), sections: [.caseVault])
            XCTFail("expected caseUnreadable")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError, .caseUnreadable)
        }
    }

    func testLargeStagedRecordingStreamsThroughManyFramesAndRestoresByteForByte() async throws {
        let source = try await makeSource()
        // Bigger than one archive frame (1 MiB), so the whole path — hash,
        // encrypt, decrypt, write — runs in chunks rather than in memory.
        let bigID = UUID()
        let directory = source.profile.locations.meetingsStaging
            .appendingPathComponent(bigID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var audio = Data(count: 3 * 1024 * 1024 + 17)
        for index in stride(from: 0, to: audio.count, by: 1024) { audio[index] = UInt8(index % 253) }
        try audio.write(to: directory.appendingPathComponent("chunk-000.wav"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try MeetingFinalizeManifestStore().write(
            MeetingFinalizeManifest(recorderMeetingId: bigID, startedAt: now, endedAt: now,
                                    durationSeconds: 900, language: nil,
                                    chunkFileNames: ["chunk-000.wav"], isFinal: true),
            to: directory)

        let key = ArtifactBackupTestKeys.make()
        let archive = archiveURL(in: source.profile)
        let summary = try await ArtifactBackupEngine(environment: source.environment)
            .createArchive(at: archive, key: key, sections: [.meetings])
        XCTAssertGreaterThan(summary.totalBytes, 3 * 1024 * 1024)

        let target = try makeTarget()
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: archive, key: key, sections: [.meetings])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        let restored = try Data(contentsOf: target.locations.meetingsStaging
            .appendingPathComponent(bigID.uuidString, isDirectory: true)
            .appendingPathComponent("chunk-000.wav"))
        XCTAssertEqual(restored, audio)
    }

    func testMissingStagedChunkFailsTheBackup() async throws {
        let source = try await makeSource()
        try FileManager.default.removeItem(at: source.profile.locations.meetingsStaging
            .appendingPathComponent(source.stagedRecordingID.uuidString, isDirectory: true)
            .appendingPathComponent("chunk-000.wav"))
        do {
            _ = try await ArtifactBackupEngine(environment: source.environment)
                .createArchive(at: archiveURL(in: source.profile), key: ArtifactBackupTestKeys.make(),
                               sections: [.meetings])
            XCTFail("expected a required-file failure")
        } catch let error as ArtifactBackupError {
            XCTAssertEqual(error, .requiredFileMissing("chunk-000.wav"))
        }
    }

    func testFutureArchiveSchemaArmsNothing() async throws {
        let target = try makeTarget()
        let key = ArtifactBackupTestKeys.make()
        let archive = archiveURL(in: target)
        let manifest = ArtifactBackupManifest(
            schema: ArtifactBackupManifest.currentSchema + 1, id: UUID(), createdAt: Date(),
            flavor: "prod", appVersion: nil, appBuild: nil, sections: [.settings], entries: [],
            contentBytes: 0, warnings: [])
        let data = try JSONEncoder.artifactBackup.encode(manifest)
        let writer = try ArtifactArchiveWriter(url: archive, archiveKey: key)
        try writer.append(Data(ArtifactArchiveHeader.bigEndian32(UInt32(data.count))))
        try writer.append(data)
        try writer.finish()

        let environment = target.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        do {
            try await engine.stageRestore(from: archive, key: key, sections: [.settings])
            XCTFail("expected needsNewerApp")
        } catch {
            XCTAssertEqual(error as? ArtifactBackupError, .needsNewerApp)
        }
        XCTAssertFalse(engine.hasPendingRestore)
        XCTAssertNil(try ArtifactBackupEngine.applyPendingRestore(environment: environment))
    }

    func testTamperedArchiveIsRefusedBeforeArming() async throws {
        let source = try await makeSource()
        let key = ArtifactBackupTestKeys.make()
        let archive = archiveURL(in: source.profile)
        _ = try await ArtifactBackupEngine(environment: source.environment)
            .createArchive(at: archive, key: key)
        var bytes = try Data(contentsOf: archive)
        bytes[bytes.count - 20] ^= 0x08
        try bytes.write(to: archive)

        let target = try makeTarget()
        let environment = target.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        await XCTAssertThrowsErrorAsync(try await engine.stageRestore(
            from: archive, key: key, sections: Set(ArtifactBackupSection.allCases)))
        XCTAssertFalse(engine.hasPendingRestore)
        XCTAssertNil(target.pendingKeyStore.value)
    }

    func testWrongRecoveryKeyCannotInspectOrStage() async throws {
        let source = try await makeSource()
        let key = ArtifactBackupTestKeys.make()
        let archive = archiveURL(in: source.profile)
        _ = try await ArtifactBackupEngine(environment: source.environment)
            .createArchive(at: archive, key: key)
        let target = try makeTarget()
        let engine = ArtifactBackupEngine(environment: target.environment())
        let wrong = ArtifactBackupTestKeys.make()
        await XCTAssertThrowsErrorAsync(try await engine.inspectArchive(at: archive, key: wrong))
        await XCTAssertThrowsErrorAsync(try await engine.stageRestore(from: archive, key: wrong,
                                                                     sections: [.settings]))
        XCTAssertFalse(engine.hasPendingRestore)
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
