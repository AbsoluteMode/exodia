import Foundation

extension ProviderAccount {
    /// The Keychain account this provider account's API key is stored under, or
    /// `nil` for a server that has been removed. The built-in providers keep
    /// the names the old Models tab wrote, so no stored key has to move; a
    /// server names its own (`ServerEndpoint.keyAccount`).
    @MainActor
    func keychainAccount(in routing: AIRoutingStore) -> String? {
        switch self {
        case .soniox: return BYOKKeyStore.account(for: .soniox)
        case .deepgram: return BYOKKeyStore.account(for: .deepgram)
        case .elevenLabs: return BYOKKeyStore.account(for: .elevenLabs)
        case .openRouter: return OpenRouterLLMKeyStore.account
        case .server(let id): return routing.server(id)?.keyAccount
        }
    }
}

/// API keys by Keychain account name. Each provider account (and each server)
/// has its own account, so one provider's key can never be handed to another.
///
/// `makeStore` is the test seam: production uses the login Keychain, tests
/// inject an in-memory `TokenStore`.
struct ProviderKeyStore {
    private let makeStore: (String) -> any TokenStore

    init(makeStore: @escaping (String) -> any TokenStore = { KeychainStore(service: BuildConfig.keychainService, account: $0) }) {
        self.makeStore = makeStore
    }

    /// The key without surrounding whitespace. `nil` when nothing is stored,
    /// when only whitespace is, or when the Keychain cannot be read: in each
    /// case the account simply has no usable key.
    func read(account: String) -> String? {
        guard let stored = try? makeStore(account).read() else { return nil }
        let key = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Stores the key without surrounding whitespace, replacing any earlier one.
    func save(_ key: String, account: String) throws {
        try makeStore(account).save(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Removing a key that is not there is not an error.
    func delete(account: String) throws {
        try makeStore(account).delete()
    }
}
