import Combine
import CryptoKit
import Foundation

enum CaseVaultServiceError: Error, Equatable {
    /// A mutation produced a payload that breaks a structural invariant
    /// (missing General, duplicate project IDs, secret in an unknown project).
    /// Nothing is saved.
    case invalidPayload
}

/// Single owner of the decrypted vault payload for the process. The island
/// panel, Settings and (later) the broker all go through one instance so two
/// view models can never overwrite each other's changes.
///
/// `loadIfNeeded()` never authenticates: Touch ID is a UI gate owned by
/// `CaseViewModel`. `lock()` on a view model hides UI state only.
@MainActor
final class CaseVaultService: ObservableObject {
    static let shared = CaseVaultService(store: CaseVaultStore(), keyProvider: CaseVaultKeyStore())

    /// nil until the first successful load.
    @Published private(set) var payload: CaseVaultPayload?

    private let store: CaseVaultStoring
    private let keyProvider: CaseVaultKeyProviding
    private let now: () -> Date
    private var key: SymmetricKey?

    init(
        store: CaseVaultStoring,
        keyProvider: CaseVaultKeyProviding,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.keyProvider = keyProvider
        self.now = now
    }

    /// Returns the cached payload, or reads key + vault. A missing file creates
    /// and saves a fresh vault dated with the real clock.
    @discardableResult
    func loadIfNeeded() throws -> CaseVaultPayload {
        if let payload {
            return payload
        }
        let vaultKey = try keyProvider.readOrCreateKey()
        let loaded: CaseVaultPayload
        do {
            loaded = try store.load(using: vaultKey)
        } catch CaseVaultStoreError.missingFile {
            loaded = CaseVaultPayload(projects: [CaseProject.general(now: now())])
            try store.save(loaded, using: vaultKey)
        }
        key = vaultKey
        payload = loaded
        return loaded
    }

    /// Applies `change` to a copy, validates, saves, then publishes. If the
    /// change or validation throws, neither disk nor `payload` is touched.
    func mutate(_ change: (inout CaseVaultPayload) throws -> Void) throws {
        var working = try loadIfNeeded()
        guard let key else {
            throw CaseVaultServiceError.invalidPayload
        }
        try change(&working)
        try Self.validate(working)
        try store.save(working, using: key)
        payload = working
    }

    /// Sets the unreadable vault aside and forgets cached state; the next
    /// `loadIfNeeded()` starts a fresh vault.
    func reset() throws {
        try store.reset()
        payload = nil
        key = nil
    }

    private static func validate(_ payload: CaseVaultPayload) throws {
        let ids = payload.projects.map(\.id)
        guard ids.contains(CaseProject.generalID),
              Set(ids).count == ids.count,
              payload.secrets.allSatisfy({ secret in ids.contains(secret.projectID) })
        else {
            throw CaseVaultServiceError.invalidPayload
        }
    }
}
