import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class BackupRenderTests: XCTestCase {
    private final class InMemoryTokenStore: TokenStore {
        var value: String?
        func save(_ token: String) throws { value = token }
        func read() throws -> String? { value }
        func delete() throws { value = nil }
    }

    private func makeIsolatedModel(temporaryRoot: URL) -> BackupViewModel {
        let suiteName = "exodia.backup.render.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let localRoot = temporaryRoot.appendingPathComponent("local", isDirectory: true)
        let settingsRoot = temporaryRoot.appendingPathComponent("settings", isDirectory: true)
        let noopEngine = BackupEngineActions(
            create: { _, _ in
                ArtifactBackupSummary(
                    id: UUID(),
                    createdAt: Date(timeIntervalSince1970: 1_792_411_200),
                    totalBytes: 0,
                    fileCount: 0,
                    sections: []
                )
            },
            inspect: { _, _ in
                ArtifactBackupPreview(
                    summary: ArtifactBackupSummary(
                        id: UUID(),
                        createdAt: Date(timeIntervalSince1970: 1_792_411_200),
                        totalBytes: 0,
                        fileCount: 0,
                        sections: []
                    ),
                    warnings: []
                )
            },
            stage: { _, _, _ in }
        )
        return BackupViewModel(
            defaults: defaults,
            keyStore: InMemoryTokenStore(),
            githubTokenStore: InMemoryTokenStore(),
            local: BackupLocalStore(root: localRoot),
            settingsFiles: ConfigBackupFiles(root: settingsRoot),
            engine: noopEngine,
            changeProbe: { "" },
            idle: { true }
        )
    }

    func testBackupSettingsTabMetadataAndOrdering() {
        XCTAssertTrue(SettingsWindowTab.allCases.contains(.backup))
        XCTAssertEqual(SettingsWindowTab.backup.title, "Backup")
        XCTAssertEqual(SettingsWindowTab.backup.fallbackSystemImageName, "externaldrive.badge.timemachine")
        XCTAssertNil(SettingsWindowTab.backup.pdfResourceName)

        let all = SettingsWindowTab.allCases
        guard let backupIndex = all.firstIndex(of: .backup),
              let otherIndex = all.firstIndex(of: .other) else {
            XCTFail("Expected both .backup and .other in SettingsWindowTab.allCases")
            return
        }
        XCTAssertEqual(backupIndex + 1, otherIndex, "Backup tab must be inserted immediately before Other")
        XCTAssertEqual(all.last, .other)
    }

    func testOffscreenBackupSettingsFixtures() throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_BACKUP_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_BACKUP_RENDER_DIR for source-matched offscreen visual checks.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fixedDate = Date(timeIntervalSince1970: 1_792_411_200) // 2026-10-19 12:00:00 UTC
        let earlierDate = fixedDate.addingTimeInterval(-3_600)
        let syntheticCode = "A1B2C3D4-E5F60718-293A4B5C-6D7E8F90-12345678-9ABCDEF0-11223344-55667788-99AABBCC"

        let localSnapshots = [
            ConfigBackupSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                createdAt: fixedDate,
                reason: "Before model change",
                preferences: [
                    "sidekey.models.byokProvider": .string("soniox"),
                    "sidekey.models.llmLevel": .string("yourKey"),
                    "sidekey.preferences.transcriptionMode": .string("smart")
                ],
                credentials: ["byok.soniox.api_key": "SYNTHETIC_NEVER_SHOWN_IN_UI"]
            ),
            ConfigBackupSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                createdAt: earlierDate,
                reason: "Scheduled local checkpoint",
                preferences: [
                    "sidekey.models.byokProvider": .string("deepgram")
                ]
            )
        ]

        // 1. Main empty state (with local settings history)
        let emptyModel = makeIsolatedModel(temporaryRoot: tempRoot.appendingPathComponent("empty"))
        emptyModel.localSettingsVersions = localSnapshots
        try render(
            hosted(SettingsBackupView(model: emptyModel)),
            size: NSSize(width: 760, height: 560),
            to: directory.appendingPathComponent("backup-empty.png")
        )

        // 2. Setup Step 1: One-time recovery code & paste-back verification
        let setupCodeModel = makeIsolatedModel(temporaryRoot: tempRoot.appendingPathComponent("setup-code"))
        setupCodeModel.recoveryCode = syntheticCode
        setupCodeModel.recoverySaved = false
        setupCodeModel.statusText = "Save your recovery code in a password manager before connecting a destination."
        setupCodeModel.localSettingsVersions = localSnapshots
        try render(
            hosted(SettingsBackupView(model: setupCodeModel)),
            size: NSSize(width: 760, height: 620),
            to: directory.appendingPathComponent("backup-setup-code.png")
        )

        // 3. Setup Step 2: Connect GitHub CLI / Fine-grained PAT / Folder
        let setupConnectModel = makeIsolatedModel(temporaryRoot: tempRoot.appendingPathComponent("setup-connect"))
        setupConnectModel.recoveryCode = syntheticCode
        setupConnectModel.recoverySaved = true
        setupConnectModel.statusText = "Recovery code verified. Connect GitHub or choose a backup folder."
        setupConnectModel.localSettingsVersions = localSnapshots
        try render(
            hosted(SettingsBackupView(model: setupConnectModel)),
            size: NSSize(width: 760, height: 620),
            to: directory.appendingPathComponent("backup-setup-connect.png")
        )

        // 4. Normal configured state
        let configuredModel = makeIsolatedModel(temporaryRoot: tempRoot.appendingPathComponent("configured"))
        configuredModel.isEnabled = true
        configuredModel.recoverySaved = true
        configuredModel.destinationName = "GitHub · octocat/exodia-backup"
        configuredModel.lastBackupAt = fixedDate
        configuredModel.lastRemoteBackupAt = fixedDate.addingTimeInterval(-45)
        configuredModel.statusText = "Encrypted backup is active. Changes are saved on this Mac and uploaded to GitHub."
        configuredModel.versions = [
            BackupVersion(
                id: "v-2026-10-19-1200",
                createdAt: fixedDate,
                size: 14_820_352,
                localURL: URL(fileURLWithPath: "/tmp/synthetic-v2.exodiabackup"),
                remoteID: 102, location: .localAndGitHub
            ),
            BackupVersion(
                id: "v-2026-10-19-1100",
                createdAt: earlierDate,
                size: 14_110_208,
                localURL: nil,
                remoteID: 101, location: .github
            )
        ]
        configuredModel.localSettingsVersions = localSnapshots
        try render(
            hosted(SettingsBackupView(model: configuredModel)),
            size: NSSize(width: 760, height: 760),
            to: directory.appendingPathComponent("backup-configured.png")
        )

        // 5. Error / offline state (verifies no stale green pill is displayed)
        let errorModel = makeIsolatedModel(temporaryRoot: tempRoot.appendingPathComponent("error"))
        errorModel.isEnabled = true
        errorModel.recoverySaved = true
        errorModel.destinationName = "GitHub · octocat/exodia-backup"
        errorModel.lastBackupAt = fixedDate
        errorModel.lastRemoteBackupAt = earlierDate
        errorModel.statusText = "Local snapshot saved. Last remote upload could not complete."
        errorModel.errorMessage = "Could not upload encrypted archive to GitHub because this Mac is offline. Your local snapshot is safe."
        errorModel.versions = configuredModel.versions
        errorModel.localSettingsVersions = localSnapshots
        try render(
            hosted(SettingsBackupView(model: errorModel)),
            size: NSSize(width: 760, height: 780),
            to: directory.appendingPathComponent("backup-error.png")
        )

        // 6. Authenticated restore preview state
        let previewModel = makeIsolatedModel(temporaryRoot: tempRoot.appendingPathComponent("preview"))
        previewModel.isEnabled = true
        previewModel.recoverySaved = true
        previewModel.destinationName = "Folder · Exodia Backups"
        previewModel.lastBackupAt = fixedDate
        previewModel.lastRemoteBackupAt = fixedDate
        previewModel.needsRestart = false
        previewModel.statusText = "Backup archive verified. Select the sections to stage for restore."
        previewModel.restorePreview = ArtifactBackupPreview(
            summary: ArtifactBackupSummary(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                createdAt: fixedDate,
                totalBytes: 28_450_816,
                fileCount: 47,
                sections: Set(ArtifactBackupSection.allCases)
            ),
            warnings: [
                "2 clipboard entries referenced external files on the previous Mac that were not copied into the archive."
            ]
        )
        previewModel.localSettingsVersions = localSnapshots
        try render(
            hosted(SettingsBackupView(model: previewModel)),
            size: NSSize(width: 760, height: 780),
            to: directory.appendingPathComponent("backup-restore-preview.png")
        )
        let readyModel = makeIsolatedModel(temporaryRoot: tempRoot.appendingPathComponent("ready"))
        readyModel.recoverySaved = true
        readyModel.needsRestart = true
        readyModel.destinationName = "GitHub · octocat/Exodia-Backup"
        readyModel.statusText = "Restore is ready. Quit Exodia normally and open it again when your work is finished."
        try render(hosted(SettingsBackupView(model: readyModel)), size: NSSize(width: 760, height: 780),
                   to: directory.appendingPathComponent("backup-restore-ready.png"))

    }

    private func hosted<V: View>(_ view: V) -> some View {
        view
            .background(Color(white: 0.12))
            .environment(\.colorScheme, .dark)
    }

    private func render<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
