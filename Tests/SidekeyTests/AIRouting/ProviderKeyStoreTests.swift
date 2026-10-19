import XCTest
@testable import Sidekey

/// Which Keychain account each provider account's key lives in, and the key
/// store on top of it. Keys sit in an in-memory `TokenStore`
/// (`InMemoryTokenStore.Box`), never in the real login Keychain.
@MainActor
final class ProviderKeyStoreTests: XCTestCase {

    private func makeRouting() -> AIRoutingStore {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AIRoutingStore(defaults: defaults)
    }

    private func makeKeys(_ box: InMemoryTokenStore.Box = InMemoryTokenStore.Box()) -> ProviderKeyStore {
        ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
    }

    /// A `TokenStore` whose Keychain always refuses.
    private struct FailingTokenStore: TokenStore {
        struct Failure: Error, Equatable {}
        func save(_ token: String) throws { throw Failure() }
        func read() throws -> String? { throw Failure() }
        func delete() throws { throw Failure() }
    }

    // MARK: - Accounts

    /// The names are what the old Models tab already wrote, so every stored key
    /// keeps working. They are literals on purpose: a changed name would orphan
    /// the user's key.
    func test_accounts_are_the_legacy_keychain_names() {
        let routing = makeRouting()

        XCTAssertEqual(ProviderAccount.soniox.keychainAccount(in: routing), "byok.soniox.api_key")
        XCTAssertEqual(ProviderAccount.deepgram.keychainAccount(in: routing), "byok.deepgram.api_key")
        XCTAssertEqual(ProviderAccount.elevenLabs.keychainAccount(in: routing), "byok.elevenLabs.api_key")
        XCTAssertEqual(ProviderAccount.openRouter.keychainAccount(in: routing), "byok.openrouter.llm_api_key")

        // A server answers with its own `keyAccount`: the legacy name for one
        // the migration carried over, the per-server name for one added later.
        let migrated = ServerEndpoint(
            id: UUID(), name: "Home GPU", baseURL: "https://gpu.local:8000",
            keyAccount: "byok.selfHosted.api_key"
        )
        routing.completeMigration(routes: [:], servers: [migrated])
        let added = routing.addServer(name: "Office", baseURL: "https://llm.office.example")

        XCTAssertEqual(ProviderAccount.server(migrated.id).keychainAccount(in: routing), "byok.selfHosted.api_key")
        XCTAssertEqual(ProviderAccount.server(added.id).keychainAccount(in: routing), added.keyAccount)
    }

    func test_deleted_server_has_no_keychain_account() {
        let routing = makeRouting()
        let server = routing.addServer(name: "Home GPU", baseURL: "https://gpu.local:8000")
        XCTAssertNotNil(ProviderAccount.server(server.id).keychainAccount(in: routing))

        routing.removeServer(server.id)

        XCTAssertNil(ProviderAccount.server(server.id).keychainAccount(in: routing))
        XCTAssertNil(ProviderAccount.server(UUID()).keychainAccount(in: routing), "a server that never existed")
    }

    // MARK: - Reading

    func test_blank_key_reads_as_missing() throws {
        let box = InMemoryTokenStore.Box()
        // Written straight into the slot, the way an older build could have
        // left it: present, but only whitespace.
        try InMemoryTokenStore(account: "byok.soniox.api_key", box: box).save("  \n")
        let keys = makeKeys(box)

        XCTAssertNil(keys.read(account: "byok.soniox.api_key"))
        XCTAssertNil(keys.read(account: "byok.deepgram.api_key"), "nothing stored at all")
    }

    func test_read_trims_whitespace_around_a_key() throws {
        let box = InMemoryTokenStore.Box()
        try InMemoryTokenStore(account: "byok.soniox.api_key", box: box).save("  sk-soniox\n")

        XCTAssertEqual(makeKeys(box).read(account: "byok.soniox.api_key"), "sk-soniox")
    }

    func test_keychain_failure_reads_as_missing() {
        let keys = ProviderKeyStore(makeStore: { _ in FailingTokenStore() })

        XCTAssertNil(keys.read(account: "byok.soniox.api_key"))
    }

    // MARK: - Saving and deleting

    func test_save_stores_the_trimmed_key_under_its_account_only() throws {
        let box = InMemoryTokenStore.Box()
        let keys = makeKeys(box)

        try keys.save("  sk-soniox \n", account: "byok.soniox.api_key")

        XCTAssertEqual(
            try InMemoryTokenStore(account: "byok.soniox.api_key", box: box).read(), "sk-soniox",
            "the Keychain holds the trimmed key"
        )
        XCTAssertEqual(keys.read(account: "byok.soniox.api_key"), "sk-soniox")
        XCTAssertNil(keys.read(account: "byok.deepgram.api_key"))
    }

    func test_delete_removes_one_account_and_missing_is_not_an_error() throws {
        let keys = makeKeys()
        try keys.save("sk-soniox", account: "byok.soniox.api_key")
        try keys.save("sk-deepgram", account: "byok.deepgram.api_key")

        try keys.delete(account: "byok.soniox.api_key")
        try keys.delete(account: "byok.soniox.api_key")
        try keys.delete(account: "byok.never.stored")

        XCTAssertNil(keys.read(account: "byok.soniox.api_key"))
        XCTAssertEqual(keys.read(account: "byok.deepgram.api_key"), "sk-deepgram")
    }

    /// Reading hides a Keychain failure (the feature just reads as missing a
    /// key), but a failed save or delete has to reach the caller.
    func test_save_and_delete_surface_keychain_errors() {
        let keys = ProviderKeyStore(makeStore: { _ in FailingTokenStore() })

        XCTAssertThrowsError(try keys.save("sk-soniox", account: "byok.soniox.api_key")) { error in
            XCTAssertEqual(error as? FailingTokenStore.Failure, FailingTokenStore.Failure())
        }
        XCTAssertThrowsError(try keys.delete(account: "byok.soniox.api_key")) { error in
            XCTAssertEqual(error as? FailingTokenStore.Failure, FailingTokenStore.Failure())
        }
    }
}
