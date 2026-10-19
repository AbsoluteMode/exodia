import AppKit
import Combine
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
final class BackupViewModel: ObservableObject {
    static let shared = BackupViewModel()
    nonisolated static let keyAccount = "backup.archive-key.v1"
    @Published var isBusy = false
    @Published var isEnabled = false
    @Published var destinationName = "Not connected"
    @Published var lastBackupAt: Date?
    @Published var lastRemoteBackupAt: Date?
    @Published var statusText = "Your data is saved on this Mac. Add an encrypted backup for recovery on another Mac."
    @Published var errorMessage: String?
    @Published var recoveryCode = ""
    @Published var recoverySaved = false
    @Published var versions: [BackupVersion] = []
    @Published var restorePreview: ArtifactBackupPreview?
    @Published var needsRestart = false
    @Published var localSettingsVersions: [ConfigBackupSnapshot] = []
    @Published var restoreNotice: ArtifactRestoreOutcome?
    @Published var recoveryCheckpoint: ArtifactRecoveryCheckpoint?
    @Published var parkedItems: [ArtifactParkedItem] = []
    @Published var canCancelOperation = false

    private let defaults: UserDefaults
    private let keyStore: TokenStore
    private let githubTokenStore: TokenStore
    private let local: BackupLocalStore
    private let settingsFiles: ConfigBackupFiles
    private let engine: BackupEngineActions
    private let changeProbe: @Sendable () -> String
    private let idle: @MainActor () -> Bool
    private let providerStore: (String) -> TokenStore
    private let previousRestoreOutcome: @MainActor () -> ArtifactRestoreOutcome?
    private let archivedKeyStore: (String) -> TokenStore
    private var github: GitHubBackupTransport?
    private let delta = BackupDeltaArchive()
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var started = false
    private var keyCache: Data?
    private var needsFullBackup = true
    private var lastAttempt = Date.distantPast
    private var sourceStamp: String?
    private var restoreFile: URL?
    private var restoreKey: Data?
    private var clipboardTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()
    private enum Operation { case backup, preview, restore, connection, refresh }
    private var operationKind: Operation?
    private var temporaryPreviewFiles = Set<URL>()
    private var changeRevision = 0
    private var destinationRevision = 0
    private var captureTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         keyStore: TokenStore = KeychainStore(account: BackupViewModel.keyAccount),
         githubTokenStore: TokenStore = KeychainStore(account: "backup.github-token.v1"),
         local: BackupLocalStore = BackupLocalStore(),
         settingsFiles: ConfigBackupFiles = ConfigBackupFiles(root: ConfigBackupFiles.defaultRoot),
         engine: BackupEngineActions = .live,
         changeProbe: @escaping @Sendable () -> String = { BackupChangeProbe.stamp() },
         idle: @escaping @MainActor () -> Bool = { BackupViewModel.isIdle },
         providerStore: @escaping (String) -> TokenStore = { KeychainStore(account: $0) },
         previousRestoreOutcome: @escaping @MainActor () -> ArtifactRestoreOutcome? = { ArtifactBackupEngine.lastRestoreOutcome() },
         archivedKeyStore: @escaping (String) -> TokenStore = { KeychainStore(account: "backup.archived-key." + $0) }) {
        self.defaults = defaults; self.keyStore = keyStore
        self.githubTokenStore = githubTokenStore; self.local = local; self.settingsFiles = settingsFiles
        self.engine = engine; self.changeProbe = changeProbe; self.idle = idle; self.providerStore = providerStore; self.previousRestoreOutcome = previousRestoreOutcome; self.archivedKeyStore = archivedKeyStore
    }

    /// Runtime wiring is explicit. Merely opening a settings preview or
    /// constructing a fixture never touches credentials, disk or the network.
    func stop() {
        timer?.invalidate(); timer = nil; subscriptions.removeAll()
        operationTask?.cancel(); captureTask?.cancel(); clipboardTask?.cancel()
        started = false
    }

    func start() {
        guard !started else { return }; started = true
        recoverySaved = defaults.bool(forKey: "backup.recovery-verified.v1")
        isEnabled = defaults.bool(forKey: "backup.enabled.v1")
        destinationName = defaults.string(forKey: "backup.destination-name.v1") ?? "Not connected"
        lastBackupAt = defaults.object(forKey: "backup.last-local.v1") as? Date
        lastRemoteBackupAt = defaults.object(forKey: "backup.last-copied.v1") as? Date
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.captureSettings() } }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .exodiaBackupArtifactsChanged)
            .sink { [weak self] _ in
                self?.markDirty()
                Task { @MainActor in await self?.captureSettings() }
            }
            .store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        Task { await initialize() }
    }

    private func initialize() async {
        if let outcome = previousRestoreOutcome(),
           defaults.string(forKey: "backup.last-outcome.v1") != outcome.id.uuidString {
            restoreNotice = outcome
        }
        recoveryCheckpoint = engine.checkpoint(); parkedItems = engine.parked()
        sourceStamp = defaults.string(forKey: "backup.source-stamp.v1")
        needsFullBackup = lastBackupAt == nil || sourceStamp == nil
        await captureSettings()
        if defaults.string(forKey: "backup.destination-kind.v1") == "github" {
            do {
                guard let token = try githubTokenStore.read(), let owner = defaults.string(forKey: "backup.github-owner.v1") else {
                    throw GitHubBackupTransport.Failure.authentication
                }
                github = try GitHubBackupTransport(token: token, owner: owner)
            } catch { fail(error) }
        }
        await refreshVersionsQuietly()
        await poll()
    }

    private func key(create: Bool = true) throws -> Data {
        if let keyCache { return keyCache }
        if let encoded = try keyStore.read() {
            guard let key = Data(base64Encoded: encoded), key.count == 32 else { throw ConfigBackupError.keyUnavailable }
            keyCache = key; return key
        }
        guard create else { throw ConfigBackupError.keyUnavailable }
        // An absent key must never silently make existing archives unreadable.
        let roots = [local.root, settingsFiles.root]
        let existing = roots.contains { url in
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
                .contains { $0.hasSuffix(".exodiabackup") || $0 == "catalog.json" }
        }
        guard !existing, !recoverySaved else { throw ConfigBackupError.keyUnavailable }
        let key = ConfigBackupArchive.makeKey()
        try keyStore.save(key.base64EncodedString()); keyCache = key
        return key
    }

    func hideRecoveryCode() { recoveryCode = "" }

    func beginSetup() {
        guard !isBusy, !needsRestart else { return }
        // An already configured user reveals the credential only through the
        // authenticated Show action, never through Pause/Resume or Retry.
        if recoverySaved { recoveryCode = ""; errorMessage = nil; return }
        do { recoveryCode = try ConfigBackupArchive.recoveryCode(for: key()); errorMessage = nil }
        catch { fail(error) }
    }

    func confirmRecoveryCode(_ code: String) throws {
        let entered = try ConfigBackupArchive.key(from: code)
        guard entered == (try key()) else { throw ConfigBackupError.cannotUnlock }
        // Verify an actual independent decrypt, not a checkbox or cached-key read.
        let proof = ConfigBackupSnapshot(reason: "Recovery verification", preferences: [:])
        guard try ConfigBackupArchive.open(ConfigBackupArchive.seal(proof, key: entered), key: entered) == proof else {
            throw ConfigBackupError.cannotUnlock
        }
        recoverySaved = true; recoveryCode = ""
        defaults.set(true, forKey: "backup.recovery-verified.v1")
        errorMessage = nil
    }

    func copyRecoveryCode(pasteboard suppliedBoard: NSPasteboard? = nil,
                          suppression suppliedSuppression: ClipboardSuppression? = nil,
                          clearAfterNanoseconds: UInt64 = 120_000_000_000) {
        guard !recoveryCode.isEmpty else { return }
        let board = suppliedBoard ?? NSPasteboard.general
        let suppression = suppliedSuppression ?? ClipboardSuppression.shared
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(recoveryCode, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.writeObjects([item])
        // Privacy flags alone do not suppress Exodia's own polling watcher.
        suppression.suppressThrough(changeCount: board.changeCount)
        let copiedCount = board.changeCount
        clipboardTask?.cancel()
        clipboardTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: clearAfterNanoseconds)
            guard !Task.isCancelled, board.changeCount == copiedCount else { return }
            board.clearContents()
            suppression.suppressThrough(changeCount: board.changeCount)
        }
    }

    func showRecoveryCode() async {
        guard !isBusy else { return }
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                localizedReason: "Show your Exodia backup recovery code") else { return }
            recoveryCode = try ConfigBackupArchive.recoveryCode(for: key(create: false))
        } catch {
            let code = (error as NSError).code
            if (error as NSError).domain == LAError.errorDomain && [LAError.userCancel.rawValue, LAError.appCancel.rawValue, LAError.systemCancel.rawValue].contains(code) { return }
            errorMessage = "Your recovery code was not shown. Authenticate with your Mac password or Touch ID to try again."
        }
    }

    func connectExistingGitHub() async {
        await retainOperation(.connection) { await self.performConnectExistingGitHub() }
    }

    private func performConnectExistingGitHub() async {
        guard !isBusy, !needsRestart else { return }
        isBusy = true; errorMessage = nil; statusText = "Checking your GitHub CLI login…"
        do {
            let token = try await BackupGitHubLogin.existingToken()
            isBusy = false
            await performConnectGitHub(token: token)
        } catch { isBusy = false; fail(error) }
    }

    func connectGitHub(token: String) async {
        await retainOperation(.connection) { await self.performConnectGitHub(token: token) }
    }

    private func performConnectGitHub(token: String) async {
        guard !isBusy, !needsRestart else { return }
        isBusy = true; errorMessage = nil; statusText = "Connecting your private backup repository…"
        do {
            let transport = try await GitHubBackupTransport.connect(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            try Task.checkCancellation()
            let name = await transport.destinationName
            try githubTokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
            github = transport; destinationName = "GitHub · " + name
            selectDestination(id: "github:" + name.lowercased())
            defaults.set("github", forKey: "backup.destination-kind.v1")
            defaults.set(name.components(separatedBy: "/").first, forKey: "backup.github-owner.v1")
            defaults.set(destinationName, forKey: "backup.destination-name.v1")
            setEnabled(recoverySaved)
            await refreshVersionsQuietly()
            statusText = recoverySaved ? "Connected. Preparing your first encrypted backup…" : "Connected. Choose a backup to restore, or save a recovery code to start new backups."
            isBusy = false
            if isEnabled { await performBackupNow() }
        } catch { isBusy = false; fail(error) }
    }

    func chooseFolder() async {
        await retainOperation(.connection) { await self.performChooseFolder() }
    }

    private func performChooseFolder() async {
        guard !isBusy, !needsRestart else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a backup folder"
        panel.message = "Choose iCloud Drive, another synced folder, or an external drive. Exodia verifies the saved file; your sync service handles cloud upload."
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        guard await panel.begin() == .OK, let selected = panel.url else { return }
        do {
            try Task.checkCancellation()
            let access = selected.startAccessingSecurityScopedResource()
            defer { if access { selected.stopAccessingSecurityScopedResource() } }
            let folder = selected.lastPathComponent == "Exodia Backups" ? selected : selected.appendingPathComponent("Exodia Backups", isDirectory: true)
            try ConfigBackupFiles.ensurePrivateDirectory(folder)
            let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let folderID = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
            selectDestination(id: "folder:" + folderID)
            defaults.set(bookmark, forKey: "backup.folder-bookmark.v1")
            defaults.set("folder", forKey: "backup.destination-kind.v1")
            destinationName = "Folder · " + selected.lastPathComponent
            defaults.set(destinationName, forKey: "backup.destination-name.v1")
            setEnabled(recoverySaved)
            await refreshVersionsQuietly()
            if isEnabled { await performBackupNow() }
            else { statusText = "Folder connected. Choose a backup to restore, or save a recovery code to start new backups." }
        } catch { fail(error) }
    }

    func setEnabled(_ enabled: Bool) {
        guard !needsRestart else { return }
        guard !enabled || (recoverySaved && defaults.string(forKey: "backup.destination-kind.v1") != nil) else {
            beginSetup(); return
        }
        isEnabled = enabled; defaults.set(enabled, forKey: "backup.enabled.v1")
        if enabled { needsFullBackup = true; statusText = "Automatic encrypted backups are on." }
        else { statusText = "Automatic backup is paused. Your local settings history and existing backups are kept." }
    }

    func backupNow() async {
        await retainOperation(.backup) { await self.performBackupNow() }
    }

    private func performBackupNow() async {
        guard !isBusy, !needsRestart else { return }
        guard recoverySaved, destinationKind != nil else { beginSetup(); return }
        guard idle() else { errorMessage = ConfigBackupError.busy.localizedDescription; return }
        isBusy = true; errorMessage = nil; lastAttempt = Date()
        statusText = "Saving an encrypted copy on this Mac…"
        var unfinished: URL?
        do {
            let key = try key(), revision = changeRevision, probe = changeProbe
            let capturedStamp = await Task.detached(priority: .utility) { probe() }.value
            try Task.checkCancellation()
            let file = try await local.archiveURL(); unfinished = file
            let summary = try await engine.create(file, key)
            _ = try await engine.inspect(file, key)
            let stored = try await local.record(summary, from: file); unfinished = nil
            lastBackupAt = Date(); defaults.set(lastBackupAt, forKey: "backup.last-local.v1")
            needsFullBackup = changeRevision != revision
            sourceStamp = capturedStamp
            defaults.set(capturedStamp, forKey: "backup.source-stamp.v1")
            await refreshVersionsQuietly()
            try await copyPending(current: (summary.id, stored), key: key)
            await refreshVersionsQuietly()
            statusText = destinationKind == "github" ? "Encrypted backup uploaded to GitHub and checked." : "Encrypted backup saved and checked in your folder. Cloud sync is managed by your sync service."
            isBusy = false
        } catch {
            if let unfinished { try? FileManager.default.removeItem(at: unfinished) }
            isBusy = false; fail(error)
        }
    }

    @discardableResult
    private func copyPending(current: (UUID, URL)? = nil, key: Data) async throws -> Int {
        guard let destinationID = defaults.string(forKey: "backup.destination-id.v1") else { throw ConfigBackupError.saveFailed }
        let pending = try await local.pendingCopies(destinationID: destinationID)
        // Retry the newest first. Unsent versions remain local even if upload
        // or a provider request limit interrupts this pass.
        for record in pending.prefix(3) {
            try Task.checkCancellation()
            let file = await local.fileURL(record.summary.id)
            if current?.0 != record.summary.id {
                let verified = try await engine.inspect(file, key)
                guard verified.summary.id == record.summary.id else { throw ConfigBackupError.invalidArchive }
            }
            if destinationKind == "github" {
                guard let github else { throw GitHubBackupTransport.Failure.authentication }
                statusText = "Uploading and checking changed backup files…"
                let transfer = try await prepareTransfer(record, file: file, destinationID: destinationID, key: key)
                let store = local, snapshotID = record.summary.id
                let id = try await github.upload(file: transfer.file, summary: record.summary, key: key, resumeReleaseID: transfer.draftID,
                    onDraft: { id in try await store.recordDraft(id: snapshotID, destinationID: destinationID, draftID: id) })
                try await local.markCopied(id: record.summary.id, destinationID: destinationID, remoteID: id, depth: transfer.depth)
                if transfer.file.pathExtension == "upload" { try? FileManager.default.removeItem(at: transfer.file) }
            } else if destinationKind == "folder" {
                let folder = try backupFolder()
                let access = folder.startAccessingSecurityScopedResource()
                defer { if access { folder.stopAccessingSecurityScopedResource() } }
                let target = folder.appendingPathComponent(record.summary.id.uuidString.lowercased() + ".exodiabackup")
                let copy = Task.detached(priority: .utility) { try BackupLocalStore.copyArchive(file, to: target) }
                try await withTaskCancellationHandler(operation: { try await copy.value }, onCancel: { copy.cancel() })
                try await local.markCopied(id: record.summary.id, destinationID: destinationID)
            } else { throw ConfigBackupError.saveFailed }
            lastRemoteBackupAt = Date(); defaults.set(lastRemoteBackupAt, forKey: "backup.last-copied.v1")
        }
        return min(pending.count, 3)
    }

    private func prepareTransfer(_ record: BackupLocalStore.Record, file: URL, destinationID: String, key: Data) async throws -> (file: URL, depth: Int, draftID: Int?) {
        let output = await local.uploadFileURL(id: record.summary.id, destinationID: destinationID)
        if let prepared = record.preparation, prepared.destinationID == destinationID {
            guard (0...32).contains(prepared.depth), prepared.baseID != record.summary.id else { throw ConfigBackupError.invalidArchive }
            if let baseID = prepared.baseID {
                guard FileManager.default.fileExists(atPath: output.path), try await delta.baseID(in: output, key: key) == baseID else {
                    throw ConfigBackupError.invalidArchive
                }
                return (output, prepared.depth, prepared.draftID)
            }
            return (file, 0, prepared.draftID)
        }
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        let records = try await local.records()
        let base = records.first { $0.summary.id != record.summary.id && $0.destinationID == destinationID
            && $0.remoteID != nil && ($0.uploadedDepth ?? 0) < 32 }
        let baseFile = base.map { record in local.root.appendingPathComponent(record.summary.id.uuidString.lowercased() + ".exodiabackup") }
        let prepared = try await delta.prepare(full: file, base: baseFile, output: output, key: key)
        let depth = prepared.baseID == nil ? 0 : (base?.uploadedDepth ?? 0) + 1
        try await local.recordPreparation(id: record.summary.id,
            preparation: .init(destinationID: destinationID, baseID: prepared.baseID, depth: depth))
        return (prepared.file, depth, nil)
    }

    func refreshVersions() async {
        await retainOperation(.refresh) { await self.performRefreshVersions() }
    }

    private func performRefreshVersions() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        errorMessage = nil
        await refreshVersionsQuietly()
    }
    private func refreshVersionsQuietly() async {
        do {
            let revision = destinationRevision
            var all = try await local.versions(destinationID: defaults.string(forKey: "backup.destination-id.v1"))
            if destinationKind == "github", let github {
                for version in try await github.versions() where !all.contains(where: { $0.id == version.id }) { all.append(version) }
            } else if destinationKind == "folder" {
                let folder = try backupFolder()
                let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }
                let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey], options: [.skipsHiddenFiles])
                for file in urls where file.pathExtension == "exodiabackup" {
                    guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !all.contains(where: { $0.id == id.uuidString }) else { continue }
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    all.append(BackupVersion(id: id.uuidString, createdAt: values.creationDate ?? .distantPast,
                                             size: Int64(values.fileSize ?? 0), localURL: file, remoteID: nil, location: .folder))
                }
            }
            guard revision == destinationRevision else { return }
            versions = all.sorted { $0.createdAt > $1.createdAt }
        } catch { fail(error) }
    }

    func prepareRestore(version: BackupVersion, code: String) async {
        await retainOperation(.preview) { await self.performPrepareRestore(version: version, code: code) }
    }

    private func performPrepareRestore(version: BackupVersion, code: String) async {
        guard !isBusy, !needsRestart else { return }
        isBusy = true; errorMessage = nil; statusText = "Opening and checking the backup…"
        do {
            clearPreview()
            let key = try ConfigBackupArchive.key(from: code)
            let file: URL
            if let localURL = version.localURL { file = localURL }
            else {
                guard let github else { throw GitHubBackupTransport.Failure.authentication }
                file = try previewURL()
                do { try await github.download(version: version, to: file, key: key) }
                catch { try? FileManager.default.removeItem(at: file); throw error }
            }
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            let expanded = try await expandedArchive(file: file, key: key)
            try await preview(file: expanded, key: key)
            guard restorePreview?.summary.id.uuidString == version.id else {
                cancelRestore(); throw ConfigBackupError.invalidArchive
            }
        } catch { clearPreview(); fail(error) }
        isBusy = false
    }

    func chooseArchive(code: String) async {
        await retainOperation(.preview) { await self.performChooseArchive(code: code) }
    }

    private func performChooseArchive(code: String) async {
        guard !isBusy, !needsRestart else { return }
        let panel = NSOpenPanel(); panel.title = "Open an Exodia backup"; panel.canChooseDirectories = false
        panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let file = panel.url else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let key = try ConfigBackupArchive.key(from: code)
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            let expanded = try await expandedArchive(file: file, key: key)
            try await preview(file: expanded, key: key)
        }
        catch { clearPreview(); fail(error) }
    }

    private func expandedArchive(file: URL, key: Data) async throws -> URL {
        guard try await delta.baseID(in: file, key: key) != nil else { return file }
        var chain = [file], visited = Set<UUID>(), temporary: [URL] = []
        defer { for file in temporary { try? FileManager.default.removeItem(at: file) } }
        var current = file
        while let baseID = try await delta.baseID(in: current, key: key) {
            try Task.checkCancellation()
            guard chain.count < 33, visited.insert(baseID).inserted else { throw ConfigBackupError.invalidArchive }
            let localFile = await local.fileURL(baseID)
            if FileManager.default.fileExists(atPath: localFile.path) { current = localFile }
            else {
                guard let github else { throw GitHubBackupTransport.Failure.incomplete }
                let version = try await github.version(id: baseID)
                let downloaded = try previewURL()
                temporary.append(downloaded)
                try await github.download(version: version, to: downloaded, key: key)
                current = downloaded
            }
            chain.append(current)
        }
        let output = try previewURL()
        do { _ = try await delta.reconstruct(chain: chain, output: output, key: key); return output }
        catch { try? FileManager.default.removeItem(at: output); throw error }
    }

    private func preview(file: URL, key: Data) async throws {
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        let preview = try await engine.inspect(file, key)
        try Task.checkCancellation()
        restoreFile = file; restoreKey = key; restorePreview = preview
        statusText = "Backup checked. Choose what to restore."
    }

    func restore(sections: Set<ArtifactBackupSection>) async {
        await retainOperation(.restore) { await self.performRestore(sections: sections) }
    }

    private func performRestore(sections: Set<ArtifactBackupSection>) async {
        guard !isBusy, !needsRestart, !sections.isEmpty, let file = restoreFile, let key = restoreKey else { return }
        guard idle() else { fail(ConfigBackupError.busy); return }
        isBusy = true; errorMessage = nil; statusText = "Preparing a safe restore…"
        defer { isBusy = false }
        do {
            let access = file.startAccessingSecurityScopedResource(); defer { if access { file.stopAccessingSecurityScopedResource() } }
            statusText = "Keeping a recovery copy of this Mac…"
            var beforeFile: URL?
            do {
                let beforeKey = recoverySaved ? try self.key() : key
                let source = try await local.archiveURL(); beforeFile = source
                let summary = try await engine.create(source, beforeKey)
                _ = try await engine.inspect(source, beforeKey)
                _ = try await local.record(summary, from: source, purpose: "Before restore", recoveryOnly: true)
                beforeFile = nil
            } catch {
                if let beforeFile { try? FileManager.default.removeItem(at: beforeFile) }
                try Task.checkCancellation()
                // Broken current data must remain recoverable too. The core
                // keeps its raw before-state even when a portable export fails.
            }
            try Task.checkCancellation()
            statusText = "Preparing the selected restore…"
            try await engine.stage(file, key, sections)
            if Task.isCancelled { _ = try engine.cancelPlanned(); throw CancellationError() }
            cleanupPreviewFiles()
            needsRestart = true; restorePreview = nil; restoreKey = nil; restoreFile = nil
            statusText = "Restore is ready. Quit Exodia normally and open it again when your work is finished."
            // Keep a fresh Mac on the source recovery credential, while retaining
            // its previous local history key. A cache error must not disguise an
            // already armed transaction as a failed restore.
            if !recoverySaved {
                do {
                    let encodedPrevious = try keyStore.read()
                    let previous = encodedPrevious.flatMap { Data(base64Encoded: $0) }
                    if let previous, previous.count == 32, previous != key {
                        let id = ConfigBackupArchive.keyID(previous)
                        var ids = defaults.stringArray(forKey: "backup.archived-key-ids.v1") ?? []
                        guard ids.count < 32 || ids.contains(id) else { throw ConfigBackupError.keyUnavailable }
                        try archivedKeyStore(id).save(previous.base64EncodedString())
                        if !ids.contains(id) { ids.append(id) }
                        defaults.set(ids, forKey: "backup.archived-key-ids.v1")
                    }
                    try keyStore.save(key.base64EncodedString()); keyCache = key
                    recoverySaved = true; defaults.set(true, forKey: "backup.recovery-verified.v1")
                } catch {
                    errorMessage = "Restore is ready, but its code could not be remembered for future backups. Keep your recovery code and finish backup setup after reopening Exodia."
                }
            }
        } catch { fail(error) }
    }

    func restoreSettingsDefaults(_ section: ConfigBackupSection) async {
        await restoreSettingsBlock(section, version: ConfigBackupSnapshot(reason: "App defaults", preferences: [:]))
    }

    func restoreSettingsBlock(_ section: ConfigBackupSection, version: ConfigBackupSnapshot) async {
        guard !isBusy, !needsRestart else { return }
        guard idle() else { fail(ConfigBackupError.busy); return }
        isBusy = true; defer { isBusy = false }
        do {
            // Capture healthy current values for the selectable local history;
            // the core transaction also retains exact raw before-state if the
            // current settings themselves are damaged.
            await captureSettings()
            let key = try key()
            let (file, group) = try BackupSettingsBlockRestore.archive(version, section: section, key: key, directory: settingsFiles.root)
            defer { try? FileManager.default.removeItem(at: file) }
            try await engine.stage(file, key, [group])
            needsRestart = true
            statusText = "\(section.title) is ready to restore. Quit Exodia normally and open it again when your work is finished."
            errorMessage = nil
        } catch { fail(error) }
    }
    func cancelRestore() {
        if operationKind == .preview || operationKind == .restore { cancelCurrentOperation() }
        clearPreview()
    }
    private func clearPreview() { restorePreview = nil; restoreKey = nil; restoreFile = nil; cleanupPreviewFiles() }
    private func cleanupPreviewFiles() {
        for file in temporaryPreviewFiles { try? FileManager.default.removeItem(at: file) }
        temporaryPreviewFiles.removeAll()
    }
    private func previewURL() throws -> URL {
        let folder = local.root.appendingPathComponent("restore-work", isDirectory: true)
        try ConfigBackupFiles.ensurePrivateDirectory(folder)
        let file = folder.appendingPathComponent(UUID().uuidString + ".exodiabackup")
        temporaryPreviewFiles.insert(file)
        return file
    }
    func cancelCurrentOperation() {
        guard let task = operationTask else { return }
        if operationKind == .backup { setEnabled(false) }
        task.cancel()
        statusText = "Cancelling… Your saved data and previous backups are kept."
    }
    private func retainOperation(_ kind: Operation, _ operation: @escaping @MainActor () async -> Void) async {
        guard operationTask == nil, !isBusy else { return }
        let id = UUID(); operationID = id; operationKind = kind; canCancelOperation = true
        let task = Task { @MainActor in await operation() }
        operationTask = task
        await task.value
        guard operationID == id else { return }
        operationTask = nil; operationKind = nil; canCancelOperation = false
        if task.isCancelled {
            if kind == .preview || kind == .restore { clearPreview() }
            statusText = kind == .backup ? "Backup paused. Your local history and existing copies are kept." : "Operation cancelled. Your existing data is kept."
        }
    }
    func cancelPlannedRestore() {
        guard needsRestart, !isBusy else { return }
        do {
            _ = try engine.cancelPlanned()
            needsRestart = false
            statusText = "Planned restore cancelled. Your current data is kept."
            errorMessage = nil
        } catch { fail(error) }
    }
    func dismissRestoreNotice() {
        if let restoreNotice { defaults.set(restoreNotice.id.uuidString, forKey: "backup.last-outcome.v1") }
        restoreNotice = nil
    }
    func showRecoveryFiles() {
        guard let recoveryCheckpoint else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recoveryCheckpoint.directory])
    }
    func showParkedFiles(_ item: ArtifactParkedItem) { NSWorkspace.shared.activateFileViewerSelecting([item.parkedURL]) }
    func activateRecoveredItem(_ item: ArtifactParkedItem) {
        guard !isBusy, !needsRestart, idle() else { fail(ConfigBackupError.busy); return }
        do { try engine.activate(item); parkedItems = engine.parked(); errorMessage = nil }
        catch { fail(error) }
    }
    func clearError() { errorMessage = nil }

    private func selectDestination(id: String) {
        if defaults.string(forKey: "backup.destination-id.v1") != id {
            destinationRevision += 1
            lastRemoteBackupAt = nil
            defaults.removeObject(forKey: "backup.last-copied.v1")
        }
        defaults.set(id, forKey: "backup.destination-id.v1")
    }

    private var destinationKind: String? { defaults.string(forKey: "backup.destination-kind.v1") }
    private func backupFolder() throws -> URL {
        guard let data = defaults.data(forKey: "backup.folder-bookmark.v1") else { throw ConfigBackupError.unsafePath }
        var stale = false
        let folder = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw ConfigBackupError.unsafePath }
        return folder
    }

    private func localHistoryKeys(current: Data) throws -> [Data] {
        let ids = defaults.stringArray(forKey: "backup.archived-key-ids.v1") ?? []
        guard ids.count <= 32 else { throw ConfigBackupError.invalidArchive }
        var keys = [current]
        for id in ids {
            guard id.utf8.count == 64, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw ConfigBackupError.invalidArchive }
            if let encoded = try archivedKeyStore(id).read(), let value = Data(base64Encoded: encoded),
               value.count == 32, ConfigBackupArchive.keyID(value) == id { keys.append(value) }
        }
        return keys
    }

    private func markDirty() { needsFullBackup = true; changeRevision += 1 }

    private func captureSettings() async {
        if let running = captureTask { await running.value; await captureSettings(); return }
        let task = Task { @MainActor in
            defer { self.captureTask = nil }
            await self.performCaptureSettings()
        }
        captureTask = task
        await task.value
    }

    private func performCaptureSettings() async {
        guard !needsRestart else { return }
        do {
            let key = try key()
            let values = try ConfigBackupRegistry.capture(defaults)
            var credentials: [String: String] = [:]
            do {
                for account in try ConfigBackupRegistry.credentialAccounts(in: defaults) {
                    if let value = try providerStore(account).read() { credentials[account] = value }
                }
            } catch { throw ConfigBackupError.keyUnavailable }
            let previous = try await settingsFiles.load(keys: localHistoryKeys(current: key))
            localSettingsVersions = previous
            if previous.first?.preferences == values && previous.first?.credentials == credentials { return }
            let snapshot = ConfigBackupSnapshot(reason: "Saved on this Mac", preferences: values, credentials: credentials)
            _ = try await settingsFiles.save(ConfigBackupArchive.seal(snapshot, key: key), id: snapshot.id)
            localSettingsVersions.insert(snapshot, at: 0)
            try await settingsFiles.prune(removing: Set(localSettingsVersions.dropFirst(300).map(\.id)))
            localSettingsVersions = Array(localSettingsVersions.prefix(300))
            markDirty()
        } catch { fail(error) }
    }

    private func poll() async {
        guard !isBusy, !needsRestart else { return }
        await captureSettings()
        let probe = changeProbe
        let stamp = await Task.detached(priority: .utility) { probe() }.value
        if stamp != sourceStamp { markDirty() }
        guard isEnabled, recoverySaved, idle(), Date().timeIntervalSince(lastAttempt) >= 120 else { return }
        if needsFullBackup { await backupNow() }
        else if let pending = try? await local.pendingCopies(destinationID: defaults.string(forKey: "backup.destination-id.v1") ?? ""), !pending.isEmpty {
            await retainOperation(.backup) { await self.retryPendingCopies() }
        }
    }

    private func retryPendingCopies() async {
            isBusy = true; lastAttempt = Date()
            do {
                let copied = try await copyPending(key: key())
                if copied > 0 {
                    errorMessage = nil; statusText = "Your encrypted backup is up to date."
                    await refreshVersionsQuietly()
                }
            } catch { fail(error) }
            isBusy = false
    }

    static var isIdle: Bool {
        let state = AppState.shared
        return !state.meetingRecordingActive && !state.isMeetingRecording && state.phase == .idle && state.agentPhase == .idle
    }
    private func fail(_ error: Error) {
        if error is CancellationError || Task.isCancelled { return }
        if let error = error as? ConfigBackupError { errorMessage = error.localizedDescription }
        else if let error = error as? ArtifactBackupError { errorMessage = error.localizedDescription }
        else if let error = error as? GitHubBackupTransport.Failure { errorMessage = error.localizedDescription }
        else if (error as NSError).domain == NSURLErrorDomain {
            errorMessage = "The backup destination could not be reached. Your local copy is kept; Exodia will retry when connected."
        } else if (error as NSError).code == NSFileWriteOutOfSpaceError {
            errorMessage = "There is not enough space for a backup. Free some space or choose another destination, then retry."
        } else { errorMessage = "The backup could not finish. Your existing data and previous copies are kept. Check the destination and try again." }
    }
}

extension Notification.Name {
    static let exodiaBackupArtifactsChanged = Notification.Name("exodia.backup.artifactsChanged")
}

/// Change detection is a scheduling hint, never a substitute for the engine's
/// coherent store export and full authenticated archive validation.
enum BackupChangeProbe {
    static func stamp() -> String {
        let paths = ArtifactBackupLocations.production
        let roots = [paths.caseVault, paths.historyDatabase,
                     paths.historyDatabase.deletingLastPathComponent().appendingPathComponent("history.sqlite-wal"),
                     paths.historyAssets, paths.monitorRoot, paths.notifyRoot, paths.meetingsCatalog,
                     paths.meetingsStaging, paths.agentMemory]
        var values: [String] = []
        func add(_ file: URL) {
            var information = stat()
            guard lstat(file.path, &information) == 0, information.st_mode & S_IFMT != S_IFLNK else { return }
            values.append(file.path + ":\(information.st_ino):\(information.st_size):\(information.st_mtimespec.tv_sec):\(information.st_mtimespec.tv_nsec):\(information.st_ctimespec.tv_sec):\(information.st_ctimespec.tv_nsec)")
        }
        for root in roots {
            add(root)
            if let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey], options: [.skipsPackageDescendants]) {
                for case let file as URL in walk {
                    if values.count >= ArtifactBackupManifest.maxEntries { return "over-limit-" + UUID().uuidString }
                    add(file)
                }
            }
        }
        return SHA256.hash(data: Data(values.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
