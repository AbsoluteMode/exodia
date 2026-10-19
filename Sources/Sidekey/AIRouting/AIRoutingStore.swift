import Foundation

/// The provider account and model one feature runs on.
struct FeatureRoute: Codable, Equatable, Sendable {
    var account: ProviderAccount
    var model: String
}

/// Everything `AIRoutingStore` persists, as one JSON value.
struct AIRoutingState: Codable, Equatable {
    /// Keyed by `AIFeature.rawValue`. A feature without an entry is Not set.
    var routes: [String: FeatureRoute]
    /// What each feature was set to by the one-time migration. Later changes
    /// leave it alone, so Settings can still say what a Not set feature used
    /// to run on.
    var migratedRoutes: [String: FeatureRoute]
    var servers: [ServerEndpoint]
    /// 0 — the migration has not run.
    var migrationVersion: Int
}

/// Which provider account and model each AI feature runs on, plus the user's
/// own servers. The runtime reads a feature's route on every call, so a change
/// applies to the next dictation, meeting or agent turn.
///
/// Routes change only through a user action or the one-time migration. The
/// store never moves a feature to another provider by itself: a removed key or
/// server leaves its features Not set.
// WHY: .project-docs/decisions/2026-10-19-api-and-models.md
@MainActor
final class AIRoutingStore: ObservableObject {
    /// Shared by the Settings window and the runtime, so both see one state.
    static let shared = AIRoutingStore()

    static let defaultsKey = "sidekey.aiRouting.v1"

    private static let emptyState = AIRoutingState(
        routes: [:], migratedRoutes: [:], servers: [], migrationVersion: 0
    )

    @Published private(set) var state: AIRoutingState

    private let defaults: UserDefaults

    /// Production uses `UserDefaults.standard`. Tests pass an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.state = Self.load(from: defaults)
    }

    var isMigrated: Bool { state.migrationVersion >= 1 }

    // MARK: - Routes

    func route(for feature: AIFeature) -> FeatureRoute? {
        state.routes[feature.rawValue]
    }

    /// The route the migration chose for `feature`, if any. Not affected by
    /// later changes.
    func migratedRoute(for feature: AIFeature) -> FeatureRoute? {
        state.migratedRoutes[feature.rawValue]
    }

    /// `nil` un-sets the feature.
    func setRoute(_ route: FeatureRoute?, for feature: AIFeature) {
        var updated = state
        updated.routes[feature.rawValue] = route
        commit(updated)
    }

    /// Un-sets every feature that runs on `account`, for example after its key
    /// was removed. Returns them in registry order so the UI can say which
    /// features were left without a model. The migration snapshot stays.
    @discardableResult
    func clearRoutes(using account: ProviderAccount) -> [AIFeature] {
        let cleared = AIFeature.allCases.filter { state.routes[$0.rawValue]?.account == account }
        var updated = state
        for feature in cleared {
            updated.routes[feature.rawValue] = nil
        }
        commit(updated)
        return cleared
    }

    // MARK: - Servers

    func server(_ id: UUID) -> ServerEndpoint? {
        state.servers.first { $0.id == id }
    }

    /// Adds a server under a fresh ID. Its key, if the user sets one, belongs
    /// in the Keychain account named by the returned `keyAccount`.
    @discardableResult
    func addServer(name: String, baseURL: String) -> ServerEndpoint {
        let id = UUID()
        let server = ServerEndpoint(
            id: id, name: name, baseURL: baseURL,
            keyAccount: "byok.server.\(id.uuidString.lowercased()).api_key"
        )
        var updated = state
        updated.servers.append(server)
        commit(updated)
        return server
    }

    /// Removes the server and un-sets every feature that ran on it. Those
    /// features become Not set; none moves to another provider.
    func removeServer(_ id: UUID) {
        var updated = state
        updated.servers.removeAll { $0.id == id }
        updated.routes = updated.routes.filter { $0.value.account != .server(id) }
        commit(updated)
    }

    // MARK: - Migration

    /// Records the one-time migration of the old Models-tab settings: the routes
    /// it chose (also kept as the "selected before migration" snapshot), the
    /// servers it carried over, and the version marker.
    func completeMigration(routes: [AIFeature: FeatureRoute], servers: [ServerEndpoint]) {
        let byFeature = Dictionary(uniqueKeysWithValues: routes.map { ($0.key.rawValue, $0.value) })
        commit(AIRoutingState(
            routes: byFeature, migratedRoutes: byFeature, servers: servers, migrationVersion: 1
        ))
    }

    // MARK: - Persistence

    /// Anything unreadable (garbage bytes, a shape this build does not know, an
    /// account it does not know) reads as the empty, unmigrated state. Loading
    /// never writes; the stored value is replaced by the next real change.
    private static func load(from defaults: UserDefaults) -> AIRoutingState {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(AIRoutingState.self, from: data)
        else { return emptyState }
        return stored
    }

    /// Applies a change in one step (one `objectWillChange`) and saves the
    /// whole state. A change that alters nothing neither publishes nor writes.
    private func commit(_ updated: AIRoutingState) {
        guard updated != state else { return }
        state = updated
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do {
            defaults.set(try encoder.encode(updated), forKey: Self.defaultsKey)
        } catch {
            assertionFailure("AIRoutingState cannot be encoded: \(error)")
        }
    }
}
