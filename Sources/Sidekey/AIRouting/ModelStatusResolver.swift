import Foundation

/// The badge on a feature's row in API & Models.
enum ModelRowStatus: Equatable {
    case ok
    case notSet
    case keyProblem
    case notVerified
    case removedByProvider
    case deprecatedAlias(of: String)
    case expiring(Date)
    case notSupported(reason: String)
}

/// How one model looks in a picker.
enum PickerOptionState: Equatable {
    case verified
    case new
    case notSupported(reason: String)
}

struct PickerOption: Equatable {
    let model: String
    let state: PickerOptionState
    let isSelected: Bool
    let hint: String?
}

/// One provider account's block in a feature's model picker.
struct PickerSection: Equatable {
    let account: ProviderAccount
    let title: String
    let options: [PickerOption]
    /// `"Not supported yet: a, b, c +N (reason)"`, or `nil` when every model fits.
    let notSupportedSummary: String?
    /// The latest catalog refresh failed: the list is the cached one.
    let refreshFailed: Bool
}

/// One "Switch" action: several features sit on the same deprecated alias of
/// the same account and can move to its replacement together.
struct AliasGroupAction: Equatable {
    let account: ProviderAccount
    let from: String
    let to: String
    let features: [AIFeature]
}

extension OpenRouterLLMError {
    /// The provider turned the model itself down (bad request, not found,
    /// unprocessable), as opposed to a key, quota or outage problem.
    var isModelRefusal: Bool {
        guard case .unexpectedStatus(let status, _) = self else { return false }
        return [400, 404, 422].contains(status)
    }
}

/// Derives what API & Models shows from the stores: the status of each
/// feature's row, the picker sections and the group "Switch" actions. Pure
/// reads of local state; it never touches the network.
@MainActor
struct ModelStatusResolver {
    static let refusedReason = "The provider refused this model"

    private static let builtInAccounts: [ProviderAccount] = [.soniox, .deepgram, .elevenLabs, .openRouter]

    private let routing: AIRoutingStore
    private let keys: ProviderKeyStore
    private let catalogs: ModelCatalogStore
    private let checks: ModelCheckStore
    private let keyStatuses: KeyStatusStore
    private let adapterVersion: (AIProviderKind, ModelUse) -> Int

    init(
        routing: AIRoutingStore,
        keys: ProviderKeyStore,
        catalogs: ModelCatalogStore,
        checks: ModelCheckStore,
        keyStatuses: KeyStatusStore,
        adapterVersion: @escaping (AIProviderKind, ModelUse) -> Int = ModelRegistry.adapterVersion
    ) {
        self.routing = routing
        self.keys = keys
        self.catalogs = catalogs
        self.checks = checks
        self.keyStatuses = keyStatuses
        self.adapterVersion = adapterVersion
    }

    // MARK: - Row status

    func status(for feature: AIFeature) -> ModelRowStatus {
        guard let route = routing.route(for: feature) else { return .notSet }
        let account = route.account
        let credential = credential(of: account)
        if credential == .missing { return .notSet }
        if credential == .unreadable { return .keyProblem }
        if case .rejected = keyStatuses.record(for: account)?.status { return .keyProblem }

        guard let use = feature.modelUse(on: account.kind) else {
            return .notSupported(reason: "\(account.kind.displayName) can't serve \(feature.title)")
        }

        let snapshot = catalogs.snapshot(for: account)
        let entry = snapshot?.models.first { $0.id == route.model }
        // An empty list says nothing (ElevenLabs lists no speech models, a
        // server may have no /models), and a stale or partial one is never
        // grounds to call a model gone (Review Focus 4).
        if let snapshot, snapshot.isAuthoritative, !snapshot.models.isEmpty, entry == nil {
            return .removedByProvider
        }
        if let target = entry?.aliasOf { return .deprecatedAlias(of: target) }
        if let expiry = entry?.expiresAt { return .expiring(expiry) }
        if checks.refusedModel(for: feature) == route.model {
            return .notSupported(reason: Self.refusedReason)
        }
        if let reason = failedProbeReason(model: route.model, account: account, use: use) {
            return .notSupported(reason: reason)
        }
        return isVerified(model: route.model, account: account, feature: feature, use: use) ? .ok : .notVerified
    }

    // MARK: - Picker

    func sections(for feature: AIFeature) -> [PickerSection] {
        let selected = routing.route(for: feature)
        var accounts = Self.builtInAccounts.filter { credential(of: $0) != .missing }
        let servers = routing.state.servers.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        accounts += servers.map { ProviderAccount.server($0.id) }

        return accounts.compactMap { account in
            guard let use = feature.modelUse(on: account.kind) else { return nil }
            let snapshot = catalogs.snapshot(for: account)
            let isSelected: (String) -> Bool = { selected?.account == account && selected?.model == $0 }

            var seen = Set<String>()
            var ids: [String] = []
            func add(_ id: String) { if seen.insert(id).inserted { ids.append(id) } }
            for model in ModelRegistry.models where model.kind == account.kind && model.uses.contains(use) {
                add(model.id)
            }
            for model in (snapshot?.models ?? []).sorted(by: { $0.id < $1.id })
            where model.aliasOf == nil || isSelected(model.id) {
                add(model.id)
            }
            if let selected, selected.account == account { add(selected.model) }

            var options: [PickerOption] = []
            var unsupported: [(model: String, reason: String)] = []
            for id in ids {
                let state = verdict(model: id, account: account, for: feature)
                if case .notSupported(let reason) = state, !isSelected(id) {
                    unsupported.append((id, reason))
                    continue
                }
                options.append(PickerOption(
                    model: id, state: state, isSelected: isSelected(id),
                    hint: hint(model: id, account: account, feature: feature, use: use)
                ))
            }
            return PickerSection(
                account: account,
                title: title(of: account),
                options: options,
                notSupportedSummary: Self.summary(of: unsupported),
                refreshFailed: snapshot?.lastRefreshFailed ?? false
            )
        }
    }

    func missingProviderHint(for feature: AIFeature) -> String? {
        guard sections(for: feature).isEmpty else { return nil }
        let names = AIProviderKind.allCases
            .filter { feature.modelUse(on: $0) != nil }
            .map(Self.phrase(for:))
        guard let last = names.last else { return nil }
        if names.count == 1 { return "Add a key for \(last)" }
        return "Add a key for \(names.dropLast().joined(separator: ", ")) or \(last)"
    }

    func verdict(model: String, account: ProviderAccount, for feature: AIFeature) -> PickerOptionState {
        let kind = account.kind
        guard let use = feature.modelUse(on: kind) else {
            return .notSupported(reason: "\(kind.displayName) can't serve \(feature.title)")
        }
        if let reason = ModelRegistry.knownUnsupportedReason(model, kind: kind, use: use) {
            return .notSupported(reason: reason)
        }
        if let entry = catalogs.snapshot(for: account)?.models.first(where: { $0.id == model }),
           let reason = contradiction(entry, feature: feature, use: use) {
            return .notSupported(reason: reason)
        }
        if let reason = failedProbeReason(model: model, account: account, use: use) {
            return .notSupported(reason: reason)
        }
        return isVerified(model: model, account: account, feature: feature, use: use) ? .verified : .new
    }

    // MARK: - Switch actions

    func aliasGroups() -> [AliasGroupAction] {
        struct Key: Hashable { let account: ProviderAccount; let from: String; let to: String }
        var order: [Key] = []
        var members: [Key: [AIFeature]] = [:]
        for feature in AIFeature.allCases {
            guard let route = routing.route(for: feature),
                  case .deprecatedAlias(let target) = status(for: feature)
            else { continue }
            let key = Key(account: route.account, from: route.model, to: target)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(feature)
        }
        return order.compactMap { key in
            guard let features = members[key], features.count >= 2 else { return nil }
            return AliasGroupAction(account: key.account, from: key.from, to: key.to, features: features)
        }
    }

    // MARK: - Pieces

    private enum Credential { case present, missing, unreadable }

    /// A built-in provider needs its key; a server may run without one. An
    /// unreadable Keychain item is a key problem, never "no key".
    private func credential(of account: ProviderAccount) -> Credential {
        guard let keychainAccount = account.keychainAccount(in: routing) else { return .missing }
        switch keys.lookup(account: keychainAccount) {
        case .key: return .present
        case .unreadable: return .unreadable
        case .absent:
            if case .server = account { return .present }
            return .missing
        }
    }

    private func title(of account: ProviderAccount) -> String {
        if case .server(let id) = account, let server = routing.server(id) { return server.name }
        return account.kind.displayName
    }

    private func checkKey(model: String, account: ProviderAccount, use: ModelUse) -> ModelCheckKey {
        ModelCheckKey(account: account.storageID, model: model, use: use)
    }

    /// A failed probe counts only for the adapter that ran it.
    private func failedProbeReason(model: String, account: ProviderAccount, use: ModelUse) -> String? {
        guard let record = checks.record(for: checkKey(model: model, account: account, use: use)),
              record.adapterVersion == adapterVersion(account.kind, use),
              case .failed(let reason) = record.outcome
        else { return nil }
        return reason
    }

    /// In the registry; or probed and passed by the current adapter; or what
    /// the migration set up while every adapter was still at version 1.
    private func isVerified(model: String, account: ProviderAccount, feature: AIFeature, use: ModelUse) -> Bool {
        let version = adapterVersion(account.kind, use)
        if ModelRegistry.isVerified(model, kind: account.kind, use: use) { return true }
        if let record = checks.record(for: checkKey(model: model, account: account, use: use)),
           record.adapterVersion == version, record.outcome == .passed {
            return true
        }
        if let migrated = routing.migratedRoute(for: feature),
           migrated.account == account, migrated.model == model, version == 1 {
            return true
        }
        return false
    }

    /// Why the catalog's own description rules a model out for this use.
    private func contradiction(_ entry: CatalogModel, feature: AIFeature, use: ModelUse) -> String? {
        switch use {
        case .realtimeSTT:
            if let uses = entry.uses, !uses.contains(.realtimeSTT) { return "recorded only" }
        case .asyncSTT:
            if let uses = entry.uses, !uses.contains(.asyncSTT) { return "real-time only" }
        case .chat:
            if let uses = entry.uses, !uses.contains(.chat) { return "not a text model" }
        case .chatWithTools:
            if entry.supportsTools == false { return "no tool support" }
            if let uses = entry.uses, !uses.contains(.chatWithTools) { return "no tool support" }
        }
        let minimum: Int?
        switch feature {
        case .agent: minimum = ModelRegistry.agentMinContext
        case .meetingNotes: minimum = ModelRegistry.meetingNotesMinContext
        case .dropFast, .dropSmart, .dropSmartCleanup, .meetings, .agentVoice, .voiceSearch: minimum = nil
        }
        if let minimum, let context = entry.contextLength, context < minimum {
            return "context under 64K tokens"
        }
        return nil
    }

    private func hint(model: String, account: ProviderAccount, feature: AIFeature, use: ModelUse) -> String? {
        switch feature {
        case .dropSmartCleanup:
            let entry = catalogs.snapshot(for: account)?.models.first { $0.id == model }
            return entry?.reasoning?.mandatory == true ? "always reasons, slower" : nil
        case .meetings:
            let registered = ModelRegistry.models.first {
                $0.kind == account.kind && $0.id == model && $0.uses.contains(use)
            }
            return registered?.diarization == true ? "with speakers" : nil
        case .dropFast, .dropSmart, .meetingNotes, .agent, .agentVoice, .voiceSearch:
            return nil
        }
    }

    private static let namesPerReason = 3

    private static func summary(of unsupported: [(model: String, reason: String)]) -> String? {
        guard !unsupported.isEmpty else { return nil }
        var reasons: [String] = []
        var byReason: [String: [String]] = [:]
        for item in unsupported {
            if byReason[item.reason] == nil { reasons.append(item.reason) }
            byReason[item.reason, default: []].append(item.model)
        }
        let groups = reasons.map { reason -> String in
            let names = byReason[reason] ?? []
            var text = names.prefix(namesPerReason).joined(separator: ", ")
            if names.count > namesPerReason { text += " +\(names.count - namesPerReason)" }
            return "\(text) (\(reason))"
        }
        return "Not supported yet: " + groups.joined(separator: "; ")
    }

    private static func phrase(for kind: AIProviderKind) -> String {
        switch kind {
        case .soniox, .deepgram, .elevenLabs, .openRouter: return kind.displayName
        case .openAICompatible: return "an OpenAI-compatible server"
        }
    }
}
