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
    case value(name: String, groupID: UUID?)
}

struct CaseDisplayRow: Equatable, Identifiable {
    enum Kind: Equatable {
        case secret
        case group
    }

    let id: UUID
    let kind: Kind
    let displayName: String
}

enum CaseViewModelError: Error, Equatable {
    case locked
    case unlockFailed
    case duplicateName
    case missingSecret
    case missingValue
    case missingGroup
    case emptyValue
    case valueTooLong
    case invalidGroupName
    case invalidGroupOperation
    /// resetVault() called without a prior armResetVault() call. Prevents
    /// accidental single-click destruction of vault data.
    case resetNotArmed
}

@MainActor
final class CaseViewModel: ObservableObject {
    typealias IdleLockScheduler = (_ delaySeconds: Int, _ action: @escaping @MainActor () -> Void) -> CaseIdleLockCancellable

    nonisolated private static let defaultUnlockedSessionSeconds = 15 * 60
    private static let maxValueBytes = 16 * 1024
    private static let maxGroupNameCharacters = CaseProject.maxNameCharacters
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
    @Published var query = "" {
        didSet {
            refreshRows()
            if unlockState == .unlocked {
                scheduleIdleLock()
            }
        }
    }

    private let store: CaseVaultStoring
    private let keyProvider: CaseVaultKeyProviding
    private let authenticator: CaseAuthenticating
    private let pasteboard: CasePasteboardWriting
    private let now: () -> Date
    private let unlockedSessionSeconds: Int
    private let scheduleIdleLockHandler: IdleLockScheduler
    private var key: SymmetricKey?
    private var payload: CaseVaultPayload?
    private var idleLockCancellable: CaseIdleLockCancellable?
    private var idleLockGeneration = 0

    init(
        store: CaseVaultStoring = CaseVaultStore(),
        keyProvider: CaseVaultKeyProviding = CaseVaultKeyStore(),
        authenticator: CaseAuthenticating = LocalCaseAuthenticator(),
        pasteboard: CasePasteboardWriting = SystemCasePasteboard(),
        now: @escaping () -> Date = Date.init,
        unlockedSessionSeconds: Int = CaseViewModel.defaultUnlockedSessionSeconds,
        scheduleIdleLock: IdleLockScheduler? = nil
    ) {
        self.store = store
        self.keyProvider = keyProvider
        self.authenticator = authenticator
        self.pasteboard = pasteboard
        self.now = now
        self.unlockedSessionSeconds = unlockedSessionSeconds
        self.scheduleIdleLockHandler = scheduleIdleLock ?? Self.defaultScheduleIdleLock
    }

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
        // Auth + key are transient failures (retry). A vault that exists but
        // can't be decrypted is a distinct, non-transient state -> .needsReset.
        let vaultKey: SymmetricKey
        do {
            try await authenticator.authenticate(reason: Self.unlockReason)
            vaultKey = try keyProvider.readOrCreateKey()
        } catch {
            failUnlock()
            throw CaseViewModelError.unlockFailed
        }

        let loadedPayload: CaseVaultPayload
        do {
            loadedPayload = try store.load(using: vaultKey)
        } catch CaseVaultStoreError.missingFile {
            loadedPayload = CaseVaultPayload()
            do {
                try store.save(loadedPayload, using: vaultKey)
            } catch {
                failUnlock()
                throw CaseViewModelError.unlockFailed
            }
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

        key = vaultKey
        payload = loadedPayload
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
        try store.reset()
        unlockState = .locked
    }

    func lock() {
        idleLockGeneration += 1
        idleLockCancellable?.cancel()
        idleLockCancellable = nil
        key = nil
        payload = nil
        rows = []
        inputMode = .name
        unlockState = .locked
    }

    func submitName(_ raw: String, groupID: UUID? = nil) throws {
        let payload = try unlockedPayload()
        let normalized = try CaseNameNormalizer.normalizedName(raw)
        guard !payload.secrets.contains(where: { $0.name.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            throw CaseViewModelError.duplicateName
        }
        if let groupID {
            guard Self.isGroupProject(groupID, in: payload) else {
                throw CaseViewModelError.missingGroup
            }
        }
        inputMode = .value(name: normalized, groupID: groupID)
        scheduleIdleLock()
    }

    func submitValue(_ value: String) throws {
        guard case let .value(name, groupID) = inputMode else {
            throw CaseNameValidationError.empty
        }
        try validateValue(value)

        var payload = try unlockedPayload()
        let timestamp = now()
        let secretID = UUID()
        let secret = CaseSecret(
            id: secretID,
            name: name,
            projectID: groupID ?? CaseProject.generalID,
            description: "",
            copyCount: 0,
            lastCopiedAt: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        payload.secrets.append(secret)
        payload.values.append(CaseSecretValue(secretID: secretID, value: value))
        if let groupID, let projectIndex = payload.projects.firstIndex(where: { $0.id == groupID }) {
            payload.projects[projectIndex].updatedAt = timestamp
        }

        try save(payload)
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

    func childRows(forGroupID groupID: UUID) -> [CaseDisplayRow] {
        guard let payload, unlockState == .unlocked, Self.isGroupProject(groupID, in: payload) else {
            return []
        }
        return payload.secrets
            .filter { $0.projectID == groupID }
            .map { CaseDisplayRow(id: $0.id, kind: .secret, displayName: $0.name) }
    }

    func copySecret(_ secretID: UUID) throws {
        var payload = try unlockedPayload()
        guard let value = payload.value(for: secretID) else {
            throw CaseViewModelError.missingValue
        }
        guard let secretIndex = payload.secrets.firstIndex(where: { $0.id == secretID }) else {
            throw CaseViewModelError.missingSecret
        }

        pasteboard.writeString(value)
        let timestamp = now()
        payload.secrets[secretIndex].copyCount += 1
        payload.secrets[secretIndex].lastCopiedAt = timestamp
        payload.secrets[secretIndex].updatedAt = timestamp
        try save(payload)
        refreshRows()
        scheduleIdleLock()
    }

    @discardableResult
    func createGroup(sourceSecretID: UUID, targetSecretID: UUID, name: String) throws -> UUID {
        guard sourceSecretID != targetSecretID else {
            throw CaseViewModelError.invalidGroupOperation
        }
        let trimmedName = try validatedGroupName(name)
        var payload = try unlockedPayload()
        guard let sourceIndex = payload.secrets.firstIndex(where: { $0.id == sourceSecretID }),
              let targetIndex = payload.secrets.firstIndex(where: { $0.id == targetSecretID })
        else {
            throw CaseViewModelError.missingSecret
        }
        guard payload.secrets[sourceIndex].projectID == CaseProject.generalID,
              payload.secrets[targetIndex].projectID == CaseProject.generalID
        else {
            throw CaseViewModelError.invalidGroupOperation
        }

        let timestamp = now()
        let projectID = UUID()
        payload.projects.append(CaseProject(
            id: projectID,
            name: trimmedName,
            description: "",
            createdAt: timestamp,
            updatedAt: timestamp
        ))
        payload.secrets[sourceIndex].projectID = projectID
        payload.secrets[sourceIndex].updatedAt = timestamp
        payload.secrets[targetIndex].projectID = projectID
        payload.secrets[targetIndex].updatedAt = timestamp

        try save(payload)
        refreshRows()
        scheduleIdleLock()
        return projectID
    }

    func addSecretToGroup(secretID: UUID, groupID: UUID) throws {
        var payload = try unlockedPayload()
        guard let secretIndex = payload.secrets.firstIndex(where: { $0.id == secretID }) else {
            throw CaseViewModelError.missingSecret
        }
        guard payload.secrets[secretIndex].projectID == CaseProject.generalID else {
            throw CaseViewModelError.invalidGroupOperation
        }
        guard Self.isGroupProject(groupID, in: payload),
              let projectIndex = payload.projects.firstIndex(where: { $0.id == groupID })
        else {
            throw CaseViewModelError.missingGroup
        }

        let timestamp = now()
        payload.secrets[secretIndex].projectID = groupID
        payload.secrets[secretIndex].updatedAt = timestamp
        payload.projects[projectIndex].updatedAt = timestamp

        try save(payload)
        refreshRows()
        scheduleIdleLock()
    }

    func removeSecretFromGroup(_ secretID: UUID) throws {
        var payload = try unlockedPayload()
        guard let secretIndex = payload.secrets.firstIndex(where: { $0.id == secretID }) else {
            throw CaseViewModelError.missingSecret
        }
        let groupID = payload.secrets[secretIndex].projectID
        guard Self.isGroupProject(groupID, in: payload),
              let projectIndex = payload.projects.firstIndex(where: { $0.id == groupID })
        else {
            throw CaseViewModelError.missingGroup
        }

        let timestamp = now()
        payload.secrets[secretIndex].projectID = CaseProject.generalID
        payload.secrets[secretIndex].updatedAt = timestamp
        payload.projects[projectIndex].updatedAt = timestamp
        Self.dissolveSmallGroups(in: &payload, at: timestamp)

        try save(payload)
        refreshRows()
        scheduleIdleLock()
    }

    func copyAll(_ groupID: UUID) throws {
        var payload = try unlockedPayload()
        guard Self.isGroupProject(groupID, in: payload),
              let projectIndex = payload.projects.firstIndex(where: { $0.id == groupID })
        else {
            throw CaseViewModelError.missingGroup
        }

        var lines: [String] = []
        var secretIndices: [Int] = []
        for secretIndex in payload.secrets.indices where payload.secrets[secretIndex].projectID == groupID {
            let secretID = payload.secrets[secretIndex].id
            guard let value = payload.value(for: secretID) else {
                throw CaseViewModelError.missingValue
            }
            secretIndices.append(secretIndex)
            lines.append("\(payload.secrets[secretIndex].name)=\(value)")
        }

        pasteboard.writeString(lines.joined(separator: "\n"))
        let timestamp = now()
        payload.projects[projectIndex].updatedAt = timestamp
        for secretIndex in secretIndices {
            payload.secrets[secretIndex].copyCount += 1
            payload.secrets[secretIndex].lastCopiedAt = timestamp
            payload.secrets[secretIndex].updatedAt = timestamp
        }

        try save(payload)
        refreshRows()
        scheduleIdleLock()
    }

    func replaceSecret(_ secretID: UUID, rawName: String, newValue: String) throws {
        try validateValue(newValue)
        var payload = try unlockedPayload()
        guard let secretIndex = payload.secrets.firstIndex(where: { $0.id == secretID }) else {
            throw CaseViewModelError.missingSecret
        }
        let normalized = try CaseNameNormalizer.normalizedName(rawName)
        guard !payload.secrets.contains(where: { secret in
            secret.id != secretID && secret.name.caseInsensitiveCompare(normalized) == .orderedSame
        }) else {
            throw CaseViewModelError.duplicateName
        }

        payload.secrets[secretIndex].name = normalized
        payload.secrets[secretIndex].updatedAt = now()
        if let valueIndex = payload.values.firstIndex(where: { $0.secretID == secretID }) {
            payload.values[valueIndex] = CaseSecretValue(secretID: secretID, value: newValue)
        } else {
            payload.values.append(CaseSecretValue(secretID: secretID, value: newValue))
        }
        try save(payload)
        refreshRows()
        scheduleIdleLock()
    }

    func renameSecret(_ secretID: UUID, rawName: String) throws {
        var payload = try unlockedPayload()
        guard let secretIndex = payload.secrets.firstIndex(where: { $0.id == secretID }) else {
            throw CaseViewModelError.missingSecret
        }
        let normalized = try CaseNameNormalizer.normalizedName(rawName)
        guard !payload.secrets.contains(where: { secret in
            secret.id != secretID && secret.name.caseInsensitiveCompare(normalized) == .orderedSame
        }) else {
            throw CaseViewModelError.duplicateName
        }

        payload.secrets[secretIndex].name = normalized
        payload.secrets[secretIndex].updatedAt = now()
        try save(payload)
        refreshRows()
        scheduleIdleLock()
    }

    func deleteSecret(_ secretID: UUID) throws {
        var payload = try unlockedPayload()
        payload.secrets.removeAll { $0.id == secretID }
        payload.values.removeAll { $0.secretID == secretID }
        Self.dissolveSmallGroups(in: &payload, at: now())
        try save(payload)
        refreshRows()
        scheduleIdleLock()
    }

    func expireUnlockedSessionForTesting() {
        lock()
    }

    private func unlockedPayload() throws -> CaseVaultPayload {
        guard let payload, key != nil, unlockState == .unlocked else {
            throw CaseViewModelError.locked
        }
        return payload
    }

    private func save(_ payload: CaseVaultPayload) throws {
        guard let key else {
            throw CaseViewModelError.locked
        }
        try store.save(payload, using: key)
        self.payload = payload
    }

    private func validateValue(_ value: String) throws {
        guard !value.isEmpty else {
            throw CaseViewModelError.emptyValue
        }
        guard value.utf8.count <= Self.maxValueBytes else {
            throw CaseViewModelError.valueTooLong
        }
    }

    /// Interim group model: a non-General project is shown as a group, and a
    /// group with fewer than two keys falls back into General.
    private static func isGroupProject(_ id: UUID, in payload: CaseVaultPayload) -> Bool {
        id != CaseProject.generalID && payload.projects.contains { $0.id == id }
    }

    private static func dissolveSmallGroups(in payload: inout CaseVaultPayload, at timestamp: Date) {
        let small = Set(payload.projects.map(\.id).filter { id in
            id != CaseProject.generalID && payload.secrets.filter { $0.projectID == id }.count < 2
        })
        guard !small.isEmpty else { return }
        for index in payload.secrets.indices where small.contains(payload.secrets[index].projectID) {
            payload.secrets[index].projectID = CaseProject.generalID
            payload.secrets[index].updatedAt = timestamp
        }
        payload.projects.removeAll { small.contains($0.id) }
    }

    private func validatedGroupName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxGroupNameCharacters else {
            throw CaseViewModelError.invalidGroupName
        }
        return trimmed
    }

    private func refreshRows() {
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
                kind: entry.kind == .secret ? .secret : .group,
                displayName: entry.displayName
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
        key = nil
        payload = nil
        rows = []
        inputMode = .name
        unlockState = .failed(Self.sanitizedUnlockFailureMessage)
    }

    private func failNeedsReset() {
        idleLockGeneration += 1
        idleLockCancellable?.cancel()
        idleLockCancellable = nil
        key = nil
        payload = nil
        rows = []
        inputMode = .name
        unlockState = .needsReset(Self.needsResetMessage)
    }

    private func failNeedsNewerApp() {
        idleLockGeneration += 1
        idleLockCancellable?.cancel()
        idleLockCancellable = nil
        key = nil
        payload = nil
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
