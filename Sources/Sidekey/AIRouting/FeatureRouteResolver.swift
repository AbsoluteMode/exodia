import Foundation

/// Why a feature cannot run on its route right now.
enum FeatureRouteError: Error, Equatable {
    /// No route, no model, or the server the route named was removed.
    case notSet(AIFeature)
    /// The route's provider account has no key.
    case missingKey(AIFeature)
    /// The route's server has no base URL.
    case missingBaseURL(AIFeature)
    /// The route's server has a base URL no connection can be built from.
    case invalidBaseURL(AIFeature)
    /// The Deepgram model cannot take the input language. The resolver does not
    /// know the language, so this comes from the session factory that does.
    case invalidLanguageConfiguration(AIFeature, DeepgramLanguageConfigurationError)

    var feature: AIFeature {
        switch self {
        case .notSet(let feature), .missingKey(let feature),
             .missingBaseURL(let feature), .invalidBaseURL(let feature),
             .invalidLanguageConfiguration(let feature, _):
            return feature
        }
    }
}

/// A feature's route with everything a call needs: the model, and the key of
/// the route's own provider account.
struct ResolvedRoute: Equatable, Sendable {
    let feature: AIFeature
    let account: ProviderAccount
    let model: String
    /// Set for every built-in provider: the resolver refuses a route without
    /// its key. A server's key is optional, so this is `nil` when it has none.
    let apiKey: String?
    /// The endpoint, when the account is a server.
    let server: ServerEndpoint?
}

/// Turns the route stored for a feature into a `ResolvedRoute`, or says why it
/// cannot run. It reads only the route's own provider account: a missing key
/// is `missingKey`, never a reason to use another provider.
@MainActor
struct FeatureRouteResolver {
    /// `nil` means the shared store, looked up when a route is resolved.
    private let injectedRouting: AIRoutingStore?
    private let keys: ProviderKeyStore

    private var routing: AIRoutingStore { injectedRouting ?? .shared }

    /// `routing` defaults to the shared store. The init touches no main-actor
    /// state and is `nonisolated`, so `FeatureRouteResolver()` can be a default
    /// argument of a main-actor init or function: Swift 5 evaluates default
    /// arguments outside the actor, where a main-actor init cannot be called.
    nonisolated init(routing: AIRoutingStore? = nil, keys: ProviderKeyStore = ProviderKeyStore()) {
        self.injectedRouting = routing
        self.keys = keys
    }

    func resolve(_ feature: AIFeature) throws -> ResolvedRoute {
        guard let route = routing.route(for: feature) else { throw FeatureRouteError.notSet(feature) }
        return try resolve(route, for: feature)
    }

    /// The same rules for a route that is not stored (a candidate being
    /// checked before the user picks it).
    func resolve(_ route: FeatureRoute, for feature: AIFeature) throws -> ResolvedRoute {
        let model = route.model.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank model, or a server that was removed, leaves nothing to run on.
        guard !model.isEmpty, let keyAccount = route.account.keychainAccount(in: routing) else {
            throw FeatureRouteError.notSet(feature)
        }
        let apiKey = keys.read(account: keyAccount)

        let server: ServerEndpoint?
        switch route.account {
        case .server(let id):
            guard let endpoint = routing.server(id) else { throw FeatureRouteError.notSet(feature) }
            guard !endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FeatureRouteError.missingBaseURL(feature)
            }
            // The key stays optional: plenty of self-hosted servers run without one.
            server = endpoint
        case .soniox, .deepgram, .elevenLabs, .openRouter:
            guard apiKey != nil else { throw FeatureRouteError.missingKey(feature) }
            server = nil
        }
        return ResolvedRoute(feature: feature, account: route.account, model: model, apiKey: apiKey, server: server)
    }
}
