import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class BackupRenderTests: XCTestCase {
    private var renderModels: [BackupViewModel] = []
    private var renderSession: URLSession?
    private var renderRoot: URL?

    override func tearDown() async throws {
        // NSHostingView can deliver its .task after the hidden window closes.
        // Stop rejects late deliveries; drain every retained request before
        // invalidating the session or resetting the shared protocol fixture.
        for model in renderModels { await model.stopAndWait() }
        renderModels.removeAll()
        renderSession?.invalidateAndCancel(); renderSession = nil
        StubURLProtocol.reset()
        if let renderRoot { try? FileManager.default.removeItem(at: renderRoot) }
        renderRoot = nil
    }

    private final class InMemoryTokenStore: TokenStore {
        var value: String?
        func save(_ token: String) throws { value = token }
        func read() throws -> String? { value }
        func delete() throws { value = nil }
    }

    private func makeIsolatedModel(temporaryRoot: URL, session: URLSession = GitHubBackupNetwork.session) -> BackupViewModel {
        let suiteName = "exodia.backup.render.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let localRoot = temporaryRoot.appendingPathComponent("local", isDirectory: true)
        let settingsRoot = temporaryRoot.appendingPathComponent("settings", isDirectory: true)
        var environment = ArtifactBackupEnvironment()
        environment.locations = .isolated(root: temporaryRoot)
        environment.defaults = defaults
        environment.credentialStore = { _ in InMemoryTokenStore() }
        environment.caseVaultKeys = StubCaseVaultKeys()
        environment.pendingKeyStore = InMemoryTokenStore()
        environment.recoveryKeyStore = InMemoryTokenStore()
        let engine = ArtifactBackupEngine(environment: environment)
        let fixtureEngine = BackupEngineActions(
            create: { try await engine.createArchive(at: $0, key: $1) },
            inspect: { try await engine.inspectArchive(at: $0, key: $1) },
            stage: { try await engine.stageRestore(from: $0, key: $1, sections: $2) })
        let model = BackupViewModel(
            defaults: defaults,
            keyStore: InMemoryTokenStore(),
            githubTokenStore: InMemoryTokenStore(),
            local: BackupLocalStore(root: localRoot),
            settingsFiles: ConfigBackupFiles(root: settingsRoot),
            engine: fixtureEngine,
            changeProbe: { "" },
            idle: { true }, providerStore: { _ in InMemoryTokenStore() }, previousRestoreOutcome: { nil }, githubSession: session
        )
        renderModels.append(model)
        return model
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

    func testOffscreenBackupSettingsFixtures() async throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_BACKUP_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_BACKUP_RENDER_DIR for offscreen visual checks.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        renderRoot = root
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        renderSession = session
        let fixture = BackupGitHubFixture(json: { try! JSONSerialization.data(withJSONObject: $0) })
        StubURLProtocol.handler = { request in try fixture.handle(request) }
        let model = makeIsolatedModel(temporaryRoot: root, session: session)
        await model.connectGitHub(token: "synthetic-token")
        XCTAssertTrue(model.canUseGitHubBackup)
        let disconnected = makeIsolatedModel(temporaryRoot: root.appendingPathComponent("disconnected"), session: session)
        let calendarSuite = "test.backup-calendar-render." + UUID().uuidString
        let calendarDefaults = try XCTUnwrap(UserDefaults(suiteName: calendarSuite))
        defer { calendarDefaults.removePersistentDomain(forName: calendarSuite) }
        let calendars = CalendarConnections(defaults: calendarDefaults)
        try render(hosted(SettingsBackupView(model: disconnected)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("backup-disconnected.png"))
        try render(hosted(SettingsIntegrationsView(model: disconnected, calendarConnections: calendars)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("integrations-disconnected.png"))
        await model.backupEverything()
        model.hideRecoveryCode()
        XCTAssertEqual(model.syncState, .synced)
        await model.stopAndWait() // Freeze the fixture before offscreen view tasks arrive.
        for width in [560, 760] {
            try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: width, height: 190),
                       to: directory.appendingPathComponent("backup-synced-\(width).png"))
        }
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("backup-connected.png"))
        try render(hosted(SettingsIntegrationsView(model: model, calendarConnections: calendars)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("integrations-connected.png"))
        model.recoveryCode = try ConfigBackupArchive.recoveryCode(for: Data(repeating: 0xAB, count: 32))
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("backup-code.png"))
        model.hideRecoveryCode()
        try render(hosted(SettingsBackupView(model: model, showRestore: true)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("backup-restore.png"))
        model.errorMessage = "GitHub is unavailable. Your local backup is kept."
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 560, height: 500),
                   to: directory.appendingPathComponent("backup-error.png"))
        model.errorMessage = nil
        model.setEnabled(false)
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 560, height: 500),
                   to: directory.appendingPathComponent("backup-paused.png"))
        model.setEnabled(true)
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 560, height: 500),
                   to: directory.appendingPathComponent("backup-pending.png"))
        model.isBusy = true
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 560, height: 500),
                   to: directory.appendingPathComponent("backup-syncing.png"))
        model.isBusy = false; model.needsRestart = true
        try render(hosted(SettingsBackupView(model: model)), size: NSSize(width: 760, height: 500),
                   to: directory.appendingPathComponent("backup-ready.png"))
    }

    private func hosted<V: View>(_ view: V) -> some View {
        view
            .background(Color(white: 0.12))
            .environment(\.colorScheme, .dark)
    }

    private func render<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
