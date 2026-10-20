import Foundation

/// The provider account and model one feature runs on.
struct FeatureRoute: Codable, Equatable, Sendable {
    var account: ProviderAccount
    var model: String
    /// OpenRouter only: the endpoint tag (`"deepinfra/fp4"`) the model is
    /// pinned to, with no fallback to other providers. `nil` is Auto, where
    /// OpenRouter picks. Belongs to `model`: a new model starts on Auto.
    var provider: String? = nil
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
    /// 0 — legacy migration pending; 1 — legacy routes carried over;
    /// 2 — subtitle translation detached from text Translation.
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
    /// A copy of a stored value this build did not read in full, written just
    /// before the first change replaces it.
    static let backupKey = "sidekey.aiRouting.v1.unreadable"

    private static let emptyState = AIRoutingState(
        routes: [:], migratedRoutes: [:], servers: [], migrationVersion: 0
    )

    @Published private(set) var state: AIRoutingState

    private let defaults: UserDefaults
    /// The stored value as loaded, when part or all of it could not be read.
    private var pendingBackup: Any?

    /// Production uses `UserDefaults.standard`. Tests pass an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = Self.load(from: defaults)
        self.state = loaded.state
        self.pendingBackup = loaded.unreadValue
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
        var updated = stateForEditing
        guard state.routes[feature.rawValue] != route || updated.routes[feature.rawValue] != route else { return }
        updated.routes[feature.rawValue] = route
        commit(updated)
    }

    /// Pins an OpenRouter route to one provider endpoint, or back to Auto
    /// (`nil`). Other accounts have no provider choice and are left alone.
    func setProvider(_ provider: String?, for feature: AIFeature) {
        guard var route = route(for: feature), route.account == .openRouter else { return }
        route.provider = provider
        setRoute(route, for: feature)
    }

    /// Un-sets every feature that runs on `account`, for example after its key
    /// was removed. Returns them in registry order so the UI can say which
    /// features were left without a model. The migration snapshot stays.
    @discardableResult
    func clearRoutes(using account: ProviderAccount) -> [AIFeature] {
        var updated = stateForEditing
        let cleared = AIFeature.allCases.filter { updated.routes[$0.rawValue]?.account == account }
        guard !cleared.isEmpty else { return [] }
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
        var updated = stateForEditing
        updated.servers.append(server)
        commit(updated)
        return server
    }

    /// Removes the server and un-sets every feature that ran on it. Those
    /// features become Not set; none moves to another provider.
    func removeServer(_ id: UUID) {
        var updated = stateForEditing
        guard updated.servers.contains(where: { $0.id == id })
                || updated.routes.values.contains(where: { $0.account == .server(id) }) else { return }
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

    /// Preserve the route already used by configured subtitles once, then
    /// keep it independent. An unset/deleted subtitle LLM never borrows the
    /// text translator's route on later launches.
    // WHY: .project-docs/decisions/2026-10-20-translation-tools.md
    func separateSubtitleTranslationIfNeeded() {
        guard pendingBackup == nil else { return }
        commit(stateForEditing)
    }

    /// An explicit edit already replaces a partial document (after retaining
    /// its raw backup). Split before applying that edit so a later clear,
    /// provider change or server removal cannot be undone on relaunch.
    private var stateForEditing: AIRoutingState {
        guard state.migrationVersion == 1 else { return state }
        var updated = state
        if updated.routes[AIFeature.subtitlesTranslation.rawValue] == nil,
           updated.routes[AIFeature.subtitlesAudio.rawValue] != nil,
           let previous = updated.routes[AIFeature.translation.rawValue] {
            updated.routes[AIFeature.subtitlesTranslation.rawValue] = previous
        }
        updated.migrationVersion = 2
        return updated
    }

    // MARK: - Persistence

    /// Reads entry by entry: a route or server this build does not know (an
    /// account a newer build added) is skipped and the rest is kept. A stored
    /// value that cannot be read at all still counts as migrated, with every
    /// feature Not set: running the migration again would overwrite the user's
    /// choices from the frozen old settings. Loading never writes; the first
    /// real change saves a copy of such a value under `backupKey`.
    // WHY: .project-docs/decisions/2026-10-19-api-and-models.md
    private static func load(from defaults: UserDefaults) -> (state: AIRoutingState, unreadValue: Any?) {
        guard let stored = defaults.object(forKey: defaultsKey) else { return (emptyState, nil) }
        guard let data = stored as? Data,
              let read = try? JSONDecoder().decode(LenientRoutingState.self, from: data)
        else {
            return (AIRoutingState(routes: [:], migratedRoutes: [:], servers: [], migrationVersion: 1), stored)
        }
        return (read.state, read.isComplete ? nil : data)
    }

    /// Applies a change in one step (one `objectWillChange`) and saves the
    /// whole state. A change that alters nothing neither publishes nor writes.
    private func commit(_ updated: AIRoutingState) {
        guard updated != state else { return }
        if let backup = pendingBackup {
            defaults.set(backup, forKey: Self.backupKey)
            pendingBackup = nil
        }
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

/// `AIRoutingState` read leniently: each route and server on its own, unknown
/// keys ignored, absent fields empty. A state without a version marker was
/// still written by this store after the migration, so it counts as migrated.
private struct LenientRoutingState: Decodable {
    let state: AIRoutingState
    /// Nothing was skipped.
    let isComplete: Bool

    private enum CodingKeys: String, CodingKey {
        case routes, migratedRoutes, servers, migrationVersion
    }

    /// One value that may not decode; `nil` then, instead of failing the whole.
    private struct Entry<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let routes = (try? container.decodeIfPresent([String: Entry<FeatureRoute>].self, forKey: .routes)) ?? nil
        let migrated = (try? container.decodeIfPresent([String: Entry<FeatureRoute>].self, forKey: .migratedRoutes)) ?? nil
        let servers = (try? container.decodeIfPresent([Entry<ServerEndpoint>].self, forKey: .servers)) ?? nil
        let version = (try? container.decodeIfPresent(Int.self, forKey: .migrationVersion)) ?? nil

        state = AIRoutingState(
            routes: (routes ?? [:]).compactMapValues(\.value),
            migratedRoutes: (migrated ?? [:]).compactMapValues(\.value),
            servers: (servers ?? []).compactMap(\.value),
            migrationVersion: version ?? 1
        )
        let skippedEntry = (routes ?? [:]).values.contains { $0.value == nil }
            || (migrated ?? [:]).values.contains { $0.value == nil }
            || (servers ?? []).contains { $0.value == nil }
        isComplete = routes != nil && migrated != nil && servers != nil && version != nil && !skippedEntry
    }
}
