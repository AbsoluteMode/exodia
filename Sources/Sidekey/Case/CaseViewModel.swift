import AppKit
import Combine
import CryptoKit
import Foundation
import LocalAuthentication

protocol CaseVaultStoring {
    func load(using key: SymmetricKey) throws -> CaseVaultPayload
    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws
    func reset() throws
}

extension CaseVaultStore: CaseVaultStoring {}

protocol CaseVaultKeyProviding {
    func readOrCreateKey() throws -> SymmetricKey
}

extension CaseVaultKeyStore: CaseVaultKeyProviding {}

protocol CaseAuthenticating {
    func authenticate(reason: String) async throws
}

enum CaseAuthenticationError: Error, Equatable {
    case unavailable
    case denied
}

struct LocalCaseAuthenticator: CaseAuthenticating {
    func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? CaseAuthenticationError.unavailable
        }

        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? CaseAuthenticationError.denied)
                }
            }
        }
    }
}

protocol CasePasteboardWriting: AnyObject {
    func writeString(_ value: String)
}

protocol CaseIdleLockCancellable: AnyObject {
    var isCancelled: Bool { get }
    func cancel()
}

extension DispatchWorkItem: CaseIdleLockCancellable {}

final class SystemCasePasteboard: CasePasteboardWriting {
    func writeString(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

enum CaseUnlockState: Equatable {
    case locked
    case unlocked
    case failed(String)
    /// Vault file exists but can't be decrypted with the current key — the user
    /// can reset (discard the unreadable vault) to start over.
    case needsReset(String)
    /// Vault decrypted fine but was written by a newer build (schemaVersion
    /// ahead of this binary). Data is intact; the user must update the app.
    /// Must NOT offer Reset — no data is lost or unreadable.
    case needsNewerApp(String)
}

enum CaseInputMode: Equatable {
    case name
    case value(name: String, projectID: UUID)
}

struct CaseDisplayRow: Equatable, Identifiable {
    enum Kind: Equatable {
        case project
        case secret
    }

    let id: UUID
    let kind: Kind
    let displayName: String
    let description: String
    /// For a secret, its project; for a project, its own ID.
    let projectID: UUID
}

enum CaseViewModelError: Error, Equatable {
    case locked
    case unlockFailed
    case duplicateName
    case missingSecret
    case missingValue
    case missingProject
    case emptyValue
    case valueTooLong
    case invalidProjectName
    case invalidProjectOperation
    case descriptionTooLong
    /// resetVault() called without a prior armResetVault() call. Prevents
    /// accidental single-click destruction of vault data.
    case resetNotArmed
}

@MainActor
final class CaseViewModel: ObservableObject {
    typealias IdleLockScheduler = (_ delaySeconds: Int, _ action: @escaping @MainActor () -> Void) -> CaseIdleLockCancellable

    nonisolated private static let defaultUnlockedSessionSeconds = 15 * 60
    private static let maxValueBytes = 16 * 1024
    private static let maxDescriptionCharacters = 200
    private static let maxProjectNameCharacters = CaseProject.maxNameCharacters
    private static let sanitizedUnlockFailureMessage = "Unable to unlock Case"
    private static let needsResetMessage = "Couldn't unlock this Case. Reset starts a new one and keeps the old file."
    private static let needsNewerAppMessage = "Update the app to open this Case."
    private static let unlockReason = "Unlock Case"

    @Published private(set) var unlockState: CaseUnlockState = .locked
    @Published private(set) var rows: [CaseDisplayRow] = []
    @Published private(set) var inputMode: CaseInputMode = .name
    /// Whether the first "arm" step of the two-step reset confirm has been
    /// taken. The UI calls armResetVault() on first press; resetVault() on
    /// second. Published because the panel keys its "Confirm Reset" label and
    /// warning copy off this — arming must trigger a SwiftUI re-render.
    @Published private(set) var isResetArmed = false
    /// Projects whose keys the UI shows; General starts expanded.
    @Published var expandedProjectIDs: Set<UUID> = [CaseProject.generalID]
    @Published var query = "" {
        didSet {
            refreshRows()
            if unlockState == .unlocked {
                scheduleIdleLock()
            }
        }
    }

    private let service: CaseVaultService
    private let authenticator: CaseAuthenticating
    private let pasteboard: CasePasteboardWriting
    private let now: () -> Date
    private let unlockedSessionSeconds: Int
    private let scheduleIdleLockHandler: IdleLockScheduler
    private var idleLockCancellable: CaseIdleLockCancellable?
    private var idleLockGeneration = 0
    private var serviceSubscription: AnyCancellable?

    init(
        service: CaseVaultService = .shared,
        authenticator: CaseAuthenticating = LocalCaseAuthenticator(),
        pasteboard: CasePasteboardWriting = SystemCasePasteboard(),
        now: @escaping () -> Date = Date.init,
        unlockedSessionSeconds: Int = CaseViewModel.defaultUnlockedSessionSeconds,
        scheduleIdleLock: IdleLockScheduler? = nil
    ) {
        self.service = service
        self.authenticator = authenticator
        self.pasteboard = pasteboard
        self.now = now
        self.unlockedSessionSeconds = unlockedSessionSeconds
        self.scheduleIdleLockHandler = scheduleIdleLock ?? Self.defaultScheduleIdleLock
        // Another view model (or the broker) may change the shared payload.
        // `$payload` emits in willSet, so use the emitted value, not service.payload.
        self.serviceSubscription = service.$payload.dropFirst().sink { [weak self] payload in
            self?.refreshRows(with: payload)
        }
    }

    private var payload: CaseVaultPayload? { service.payload }

    var unlockedSessionSecondsForTesting: Int {
        unlockedSessionSeconds
    }

    var hasScheduledIdleLockForTesting: Bool {
        idleLockCancellable.map { !$0.isCancelled } ?? false
    }

    var isUnlocked: Bool {
        unlockState == .unlocked
    }

    func unlock() async throws {
        // Touch ID is only the UI gate. The service reads key + vault itself
        // and never authenticates, so the broker can share it.
        do {
            try await authenticator.authenticate(reason: Self.unlockReason)
        } catch {
            failUnlock()
            throw CaseViewModelError.unlockFailed
        }

        do {
            try service.loadIfNeeded()
        } catch CaseVaultStoreError.needsNewerApp {
            // Vault decrypted successfully but was written by a newer build.
            // The data is intact — do NOT offer Reset. Direct the user to update.
            failNeedsNewerApp()
            throw CaseViewModelError.unlockFailed
        } catch let error where Self.isUndecryptableVault(error) {
            // Vault exists but won't decrypt with the current key (rotated/lost
            // key, corrupt or incompatible file). Surface a reset affordance
            // instead of dead-ending the user.
            failNeedsReset()
            throw CaseViewModelError.unlockFailed
        } catch {
            failUnlock()
            throw CaseViewModelError.unlockFailed
        }

        unlockState = .unlocked
        refreshRows()
        scheduleIdleLock()
    }

    /// First step of a two-step destructive reset confirm.
    /// Returns `true` on the first call (arms the confirm); subsequent calls
    /// to `resetVault()` will then execute the actual reset. Calling this
    /// a second time without an intervening `resetVault()` is a no-op.
    @discardableResult
    func armResetVault() -> Bool {
        guard !isResetArmed else { return false }
        isResetArmed = true
        return true
    }

    /// Clear the armed state (e.g. panel closed / user navigated away).
    func disarmResetVault() {
        isResetArmed = false
    }

    /// Set an unreadable vault aside so the next unlock starts a fresh empty
    /// one. The old file is kept next to it, never deleted; the key seam is
    /// reused.
    /// Requires a prior `armResetVault()` call — throws `resetNotArmed` otherwise,
    /// preventing accidental single-click destruction.
    func resetVault() throws {
        guard isResetArmed else {
            throw CaseViewModelError.resetNotArmed
        }
        isResetArmed = false
        try service.reset()
        unlockState = .locked
    }

    func lock() {
        idleLockGeneration += 1
        idleLockCancellable?.cancel()
        idleLockCancellable = nil
        rows = []
        inputMode = .name
        unlockState = .locked
    }

    func submitName(_ raw: String, projectID: UUID = CaseProject.generalID) throws {
        let payload = try unlockedPayload()
        let normalized = try CaseNameNormalizer.normalizedName(raw)
        guard payload.project(projectID) != nil else {
            throw CaseViewModelError.missingProject
        }
        guard !Self.hasSecret(named: normalized, inProject: projectID, in: payload, excluding: nil) else {
            throw CaseViewModelError.duplicateName
        }
        inputMode = .value(name: normalized, projectID: projectID)
        scheduleIdleLock()
    }

    func submitValue(_ value: String) throws {
        guard case let .value(name, projectID) = inputMode else {
            throw CaseNameValidationError.empty
        }
        try validateValue(value)
        _ = try unlockedPayload()

        let timestamp = now()
        let secretID = UUID()
        try service.mutate { payload in
            guard payload.project(projectID) != nil else {
                throw CaseViewModelError.missingProject
            }
            guard !Self.hasSecret(named: name, inProject: projectID, in: payload, excluding: nil) else {
                throw CaseViewModelError.duplicateName
            }
            payload.secrets.append(CaseSecret(
                id: secretID,
                name: name,
                projectID: projectID,
                description: "",
                copyCount: 0,
                lastCopiedAt: nil,
                createdAt: timestamp,
                updatedAt: timestamp
            ))
            payload.values.append(CaseSecretValue(secretID: secretID, value: value))
            if let index = payload.projects.firstIndex(where: { $0.id == projectID }) {
                payload.projects[index].updatedAt = timestamp
            }
        }
        inputMode = .name
        query = ""
        refreshRows()
        scheduleIdleLock()
    }

    func cancelInput() {
        inputMode = .name
        if query.isEmpty, unlockState == .unlocked {
            scheduleIdleLock()
        } else {
            query = ""
        }
    }

    func secretRows(inProject projectID: UUID) -> [CaseDisplayRow] {
        guard let payload, unlockState == .unlocked, payload.project(projectID) != nil else {
            return []
        }
        return payload.secrets
            .filter { $0.projectID == projectID }
            .map {
                CaseDisplayRow(id: $0.id, kind: .secret, displayName: $0.name, description: $0.description, projectID: $0.projectID)
            }
    }

    func copySecret(_ secretID: UUID) throws {
        let payload = try unlockedPayload()
        guard let value = payload.value(for: secretID) else {
            throw CaseViewModelError.missingValue
        }
        guard payload.secrets.contains(where: { $0.id == secretID }) else {
            throw CaseViewModelError.missingSecret
        }

        pasteboard.writeString(value)
        let timestamp = now()
        try service.mutate { payload in
            guard let index = payload.secrets.firstIndex(where: { $0.id == secretID }) else {
                throw CaseViewModelError.missingSecret
            }
            payload.secrets[index].copyCount += 1
            payload.secrets[index].lastCopiedAt = timestamp
            payload.secrets[index].updatedAt = timestamp
        }
        refreshRows()
        scheduleIdleLock()
    }

    @discardableResult
    func createProject(name: String, description: String) throws -> UUID {
        let trimmedName = try validatedProjectName(name)
        let trimmedDescription = try validatedDescription(description)
        _ = try unlockedPayload()
        let timestamp = now()
        let projectID = UUID()
        try service.mutate { payload in
            guard !Self.hasProject(named: trimmedName, in: payload, excluding: nil) else {
                throw CaseViewModelError.duplicateName
            }
            payload.projects.append(CaseProject(
                id: projectID,
                name: trimmedName,
                description: trimmedDescription,
                createdAt: timestamp,
                updatedAt: timestamp
            ))
        }
        expandedProjectIDs.insert(projectID)
        refreshRows()
        scheduleIdleLock()
        return projectID
    }

    func renameProject(_ id: UUID, name: String) throws {
        guard id != CaseProject.generalID else {
            throw CaseViewModelError.invalidProjectOperation
        }
        let trimmedName = try validatedProjectName(name)
        _ = try unlockedPayload()
        let timestamp = now()
        try service.mutate { payload in
            guard let index = payload.projects.firstIndex(where: { $0.id == id }) else {
                throw CaseViewModelError.missingProject
            }
            guard !Self.hasProject(named: trimmedName, in: payload, excluding: id) else {
                throw CaseViewModelError.duplicateName
            }
            payload.projects[index].name = trimmedName
            payload.projects[index].updatedAt = timestamp
        }
        refreshRows()
        scheduleIdleLock()
    }

    func setProjectDescription(_ id: UUID, _ text: String) throws {
        let trimmed = try validatedDescription(text)
        _ = try unlockedPayload()
        let timestamp = now()
        try service.mutate { payload in
            guard let index = payload.projects.firstIndex(where: { $0.id == id }) else {
                throw CaseViewModelError.missingProject
            }
            payload.projects[index].description = trimmed
            payload.projects[index].updatedAt = timestamp
        }
        refreshRows()
        scheduleIdleLock()
    }

    /// Explicit delete only: removes the project with its keys and values.
    func deleteProject(_ id: UUID) throws {
        guard id != CaseProject.generalID else {
            throw CaseViewModelError.invalidProjectOperation
        }
        _ = try unlockedPayload()
        try service.mutate { payload in
            guard payload.project(id) != nil else {
                throw CaseViewModelError.missingProject
            }
            let removed = Set(payload.secrets.filter { $0.projectID == id }.map(\.id))
            payload.secrets.removeAll { $0.projectID == id }
            payload.values.removeAll { removed.contains($0.secretID) }
            payload.projects.removeAll { $0.id == id }
            for index in payload.apps.indices {
                payload.apps[index].projectModes[id] = nil
            }
        }
        expandedProjectIDs.remove(id)
        refreshRows()
        scheduleIdleLock()
    }

    func moveSecret(_ secretID: UUID, toProject projectID: UUID) throws {
        let current = try unlockedPayload()
        guard let secret = current.secrets.first(where: { $0.id == secretID }) else {
            throw CaseViewModelError.missingSecret
        }
        guard current.project(projectID) != nil else {
            throw CaseViewModelError.missingProject
        }
        guard secret.projectID != projectID else {
            return
        }
        let timestamp = now()
        try service.mutate { payload in
            guard let index = payload.secrets.firstIndex(where: { $0.id == secretID }) else {
                throw CaseViewModelError.missingSecret
            }
            guard payload.project(projectID) != nil else {
                throw CaseViewModelError.missingProject
            }
            guard !Self.hasSecret(named: payload.secrets[index].name, inProject: projectID, in: payload, excluding: secretID) else {
                throw CaseViewModelError.duplicateName
            }
            let oldProjectID = payload.secrets[index].projectID
            payload.secrets[index].projectID = projectID
            payload.secrets[index].updatedAt = timestamp
            for touched in [oldProjectID, projectID] {
                if let projectIndex = payload.projects.firstIndex(where: { $0.id == touched }) {
                    payload.projects[projectIndex].updatedAt = timestamp
                }
            }
        }
        refreshRows()
        scheduleIdleLock()
    }

    func setSecretDescription(_ secretID: UUID, _ text: String) throws {
        let trimmed = try validatedDescription(text)
        _ = try unlockedPayload()
        let timestamp = now()
        try service.mutate { payload in
            guard let index = payload.secrets.firstIndex(where: { $0.id == secretID }) else {
                throw CaseViewModelError.missingSecret
            }
            payload.secrets[index].description = trimmed
            payload.secrets[index].updatedAt = timestamp
        }
        refreshRows()
        scheduleIdleLock()
    }

    func replaceSecret(_ secretID: UUID, rawName: String, newValue: String) throws {
        try validateValue(newValue)
        _ = try unlockedPayload()
        let normalized = try CaseNameNormalizer.normalizedName(rawName)
        let timestamp = now()
        try service.mutate { payload in
            guard let secretIndex = payload.secrets.firstIndex(where: { $0.id == secretID }) else {
                throw CaseViewModelError.missingSecret
            }
            guard !Self.hasSecret(named: normalized, inProject: payload.secrets[secretIndex].projectID, in: payload, excluding: secretID) else {
                throw CaseViewModelError.duplicateName
            }
            payload.secrets[secretIndex].name = normalized
            payload.secrets[secretIndex].updatedAt = timestamp
            if let valueIndex = payload.values.firstIndex(where: { $0.secretID == secretID }) {
                payload.values[valueIndex] = CaseSecretValue(secretID: secretID, value: newValue)
            } else {
                payload.values.append(CaseSecretValue(secretID: secretID, value: newValue))
            }
        }
        refreshRows()
        scheduleIdleLock()
    }

    func renameSecret(_ secretID: UUID, rawName: String) throws {
        _ = try unlockedPayload()
        let normalized = try CaseNameNormalizer.normalizedName(rawName)
        let timestamp = now()
        try service.mutate { payload in
            guard let secretIndex = payload.secrets.firstIndex(where: { $0.id == secretID }) else {
                throw CaseViewModelError.missingSecret
            }
            guard !Self.hasSecret(named: normalized, inProject: payload.secrets[secretIndex].projectID, in: payload, excluding: secretID) else {
                throw CaseViewModelError.duplicateName
            }
            payload.secrets[secretIndex].name = normalized
            payload.secrets[secretIndex].updatedAt = timestamp
        }
        refreshRows()
        scheduleIdleLock()
    }

    func deleteSecret(_ secretID: UUID) throws {
        _ = try unlockedPayload()
        try service.mutate { payload in
            payload.secrets.removeAll { $0.id == secretID }
            payload.values.removeAll { $0.secretID == secretID }
        }
        refreshRows()
        scheduleIdleLock()
    }

    func expireUnlockedSessionForTesting() {
        lock()
    }

    private func unlockedPayload() throws -> CaseVaultPayload {
        guard unlockState == .unlocked, let payload else {
            throw CaseViewModelError.locked
        }
        return payload
    }

    private func validateValue(_ value: String) throws {
        guard !value.isEmpty else {
            throw CaseViewModelError.emptyValue
        }
        guard value.utf8.count <= Self.maxValueBytes else {
            throw CaseViewModelError.valueTooLong
        }
    }

    private func validatedProjectName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxProjectNameCharacters else {
            throw CaseViewModelError.invalidProjectName
        }
        return trimmed
    }

    private func validatedDescription(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Self.maxDescriptionCharacters else {
            throw CaseViewModelError.descriptionTooLong
        }
        return trimmed
    }

    /// Key names are unique per project (case-insensitive), not globally.
    private static func hasSecret(
        named name: String,
        inProject projectID: UUID,
        in payload: CaseVaultPayload,
        excluding excludedID: UUID?
    ) -> Bool {
        payload.secrets.contains { secret in
            secret.id != excludedID
                && secret.projectID == projectID
                && secret.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func hasProject(named name: String, in payload: CaseVaultPayload, excluding excludedID: UUID?) -> Bool {
        payload.projects.contains { project in
            project.id != excludedID && project.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func refreshRows() {
        refreshRows(with: payload)
    }

    private func refreshRows(with payload: CaseVaultPayload?) {
        guard let payload, unlockState == .unlocked else {
            rows = []
            return
        }

        rows = CaseRanker.sortedEntries(
            secrets: payload.secrets,
            projects: payload.projects,
            query: query,
            now: now()
        )
        .map { entry in
            CaseDisplayRow(
                id: entry.id,
                kind: entry.kind == .secret ? .secret : .project,
                displayName: entry.displayName,
                description: entry.description,
                projectID: entry.projectID
            )
        }
    }

    private func scheduleIdleLock() {
        idleLockGeneration += 1
        let generation = idleLockGeneration
        idleLockCancellable?.cancel()
        idleLockCancellable = scheduleIdleLockHandler(unlockedSessionSeconds) { [weak self] in
            self?.lockIfIdleLockGenerationMatches(generation)
        }
    }

    private func lockIfIdleLockGenerationMatches(_ generation: Int) {
        guard idleLockGeneration == generation else {
            return
        }
        lock()
    }

    private func failUnlock() {
        idleLockGeneration += 1
        idleLockCancellable?.cancel()
        idleLockCancellable = nil
        rows = []
        inputMode = .name
        unlockState = .failed(Self.sanitizedUnlockFailureMessage)
    }

    private func failNeedsReset() {
        idleLockGeneration += 1
        idleLockCancellable?.cancel()
        idleLockCancellable = nil
        rows = []
        inputMode = .name
        unlockState = .needsReset(Self.needsResetMessage)
    }

    private func failNeedsNewerApp() {
        idleLockGeneration += 1
        idleLockCancellable?.cancel()
        idleLockCancellable = nil
        rows = []
        inputMode = .name
        unlockState = .needsNewerApp(Self.needsNewerAppMessage)
    }

    /// True for errors that mean "the vault file is present but unreadable with
    /// the current key" — wrong/rotated key (CryptoKit auth tag mismatch) or a
    /// corrupt/incompatible envelope. NOT missingFile (that's a fresh vault) and
    /// NOT generic/transient storage errors (those stay retryable .failed).
    private static func isUndecryptableVault(_ error: Error) -> Bool {
        if error is CryptoKitError { return true }
        if let storeError = error as? CaseVaultStoreError {
            switch storeError {
            case .invalidEnvelope, .unsupportedEnvelope:
                return true
            case .missingFile, .needsNewerApp:
                // missingFile: not an error, just a fresh vault.
                // needsNewerApp: vault decrypted fine, user needs to update the
                // app — data is intact, Reset must not be offered.
                return false
            }
        }
        return false
    }

    private static func defaultScheduleIdleLock(
        delaySeconds: Int,
        action: @escaping @MainActor () -> Void
    ) -> CaseIdleLockCancellable {
        let workItem = DispatchWorkItem {
            Task { @MainActor in
                action()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delaySeconds), execute: workItem)
        return workItem
    }
}
