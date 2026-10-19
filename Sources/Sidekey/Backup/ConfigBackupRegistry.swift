import Foundation

enum ConfigBackupSection: String, Codable, CaseIterable, Identifiable {
    case models, hotkeys, vocabulary, toolbox, other, agents, credentials
    var id: String { rawValue }
    var title: String {
        switch self {
        case .models: return "API & Models · languages"
        case .hotkeys: return "Hotkeys"
        case .vocabulary: return "Vocabulary & replacements"
        case .toolbox: return "Toolbox layout"
        case .other: return "Display & features"
        case .agents: return "Agent preferences"
        case .credentials: return "Provider keys"
        }
    }
}

/// An explicit import/export allowlist. Never copy the defaults domain: it also
/// contains migrations, installation state, updater state and file bookmarks.
enum ConfigBackupRegistry {
    enum Kind { case string, bool, strings, data }
    static let aiRoutingKey = "sidekey.aiRouting.v1"
    struct Entry {
        let section: ConfigBackupSection
        let kind: Kind
    }

    static let entries: [String: Entry] = {
        var result: [String: Entry] = [:]
        func add(_ section: ConfigBackupSection, _ kind: Kind, _ keys: [String]) {
            for key in keys { result[key] = Entry(section: section, kind: kind) }
        }
        add(.models, .string, ["sidekey.models.transcriptionLevel", "sidekey.models.byokProvider",
            "sidekey.models.selfHostedBaseURL", "sidekey.models.selfHostedModel", "sidekey.models.llmLevel",
            "sidekey.models.openRouterModel", "sidekey.models.customLLMBaseURL", "sidekey.models.customLLMModel",
            "sidekey.preferences.transcriptionMode", "sidekey.preferences.selectedLanguage", "sidekey.preferences.targetLanguage", "com.sidekey.meetings.preferredLanguage"])
        add(.models, .string, ["openAI", "selfHosted", "deepgram", "soniox", "elevenLabs"].map { "sidekey.models.byokModel." + $0 })
        add(.models, .data, [aiRoutingKey])
        add(.hotkeys, .bool, ["sidekey.preferences.brightnessKeys"])
        add(.hotkeys, .string, ["agentGestureKey", "agentTextKey", "agentVoiceKey", "agentTextShortcut",
            "agentVoiceShortcut", "agentVoiceGesture", "dropVoiceGesture", "dropVoiceTapCombo", "dropVoiceShortcut",
            "agentCloseCombo", "agentCloseShortcut", "usefulLinksInsertCombo", "usefulLinksInsertShortcut",
            "usefulLinksOpenCombo", "usefulLinksOpenShortcut", "usefulLinksNextCombo", "usefulLinksNextShortcut",
            "usefulLinksPreviousCombo", "usefulLinksPreviousShortcut", "hoverSlot1Shortcut", "hoverSlot2Shortcut",
            "hoverSlot3Shortcut", "hoverSlot4Shortcut", "hoverSlot5Shortcut", "meetingRecordShortcut"].map { "hotkeys." + $0 })
        add(.vocabulary, .strings, ["sidekey.preferences.vocabularyTerms", "sidekey.replace.terms"])
        add(.toolbox, .strings, ["sidekey.b2b.hover.layout"])
        add(.other, .bool, ["sidekey.privacy.screenshotProtectionEnabled", "sidekey.preferences.hideHelpers",
            "sidekey.preferences.hideIslandHoverWidgets", "sidekey.preferences.agentEnabled", "sidekey.preferences.meetingsEnabled",
            "sidekey.preferences.googleEnabled", "com.sidekey.meetings.enabled", "com.sidekey.volumeduck.enabled",
            "com.sidekey.nowplaying.enabled", "com.sidekey.island.idleHideEnabled"])
        add(.other, .string, ["sidekey.dynamicIsland.preferredDisplayUUID"])
        add(.agents, .string, ["agent.opencode.model", "agent.claude.model", "agent.claude.effort", "agent.codex.model", "agent.codex.effort", "agent.codex.serviceTier"])
        add(.agents, .bool, ["agent.opencode.allowActions"])
        return result
    }()

    static let credentialAccounts: Set<String> = Set(
        ["openAI", "selfHosted", "deepgram", "soniox", "elevenLabs"].map { "byok." + $0 + ".api_key" }
        + ["byok.openrouter.llm_api_key", "byok.custom_llm.api_key", "byok.anthropic.api_key"])

    /// No Keychain enumeration or caller-controlled account names. Only server
    /// IDs registered in the routing document add accounts to the export.
    static func credentialAccounts(in defaults: UserDefaults) throws -> Set<String> {
        guard let stored = defaults.object(forKey: aiRoutingKey) else { return credentialAccounts }
        guard let data = stored as? Data else { throw ConfigBackupError.invalidArchive }
        return credentialAccounts.union(try routingServers(data).map(\.keyAccount))
    }

    static func isCredentialAccount(_ account: String) -> Bool {
        if credentialAccounts.contains(account) { return true }
        let prefix = "byok.server.", suffix = ".api_key"
        guard account.hasPrefix(prefix), account.hasSuffix(suffix),
              let id = UUID(uuidString: String(account.dropFirst(prefix.count).dropLast(suffix.count))) else { return false }
        return account == "byok.server.\(id.uuidString.lowercased()).api_key"
    }

    private struct RoutingDocument: Decodable { var servers: [ServerEndpoint]? }

    private static func routingServers(_ data: Data) throws -> [ServerEndpoint] {
        guard data.count <= 262_144,
              let document = try? JSONDecoder().decode(RoutingDocument.self, from: data) else { throw ConfigBackupError.invalidArchive }
        let servers = document.servers ?? []
        let legacyAccounts: Set<String> = ["byok.selfHosted.api_key", "byok.custom_llm.api_key"]
        guard servers.count <= 256, Set(servers.map(\.id)).count == servers.count,
              servers.allSatisfy({ server in
                  (server.keyAccount == "byok.server.\(server.id.uuidString.lowercased()).api_key"
                      || legacyAccounts.contains(server.keyAccount))
                      && [server.name, server.baseURL].allSatisfy { $0.utf8.count <= 8192 && !$0.contains("\0") }
              }) else { throw ConfigBackupError.invalidArchive }
        return servers
    }

    static func capture(_ defaults: UserDefaults) throws -> [String: ConfigBackupValue] {
        var values: [String: ConfigBackupValue] = [:]
        for (key, entry) in entries {
            guard let value = defaults.object(forKey: key) else { continue }
            switch entry.kind {
            case .string:
                guard let value = value as? String else { throw ConfigBackupError.invalidArchive }
                values[key] = .string(value)
            case .bool:
                guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                    throw ConfigBackupError.invalidArchive
                }
                values[key] = .bool(value.boolValue)
            case .strings:
                guard let value = value as? [String] else { throw ConfigBackupError.invalidArchive }
                values[key] = .strings(value)
            case .data:
                guard let value = value as? Data else { throw ConfigBackupError.invalidArchive }
                values[key] = .data(value)
            }
        }
        try validate(values)
        return values
    }

    static func validate(_ values: [String: ConfigBackupValue], credentials: [String: String]? = nil) throws {
        for (key, value) in values {
            guard let entry = entries[key] else { throw ConfigBackupError.invalidArchive }
            switch (entry.kind, value) {
            case (.string, .string(let value)):
                guard value.utf8.count <= 8192, !value.contains("\0") else { throw ConfigBackupError.invalidArchive }
            case (.bool, .bool): break
            case (.data, .data(let data)): _ = try routingServers(data)
            case (.strings, .strings(let values)):
                guard values.count <= 256, values.allSatisfy({ $0.utf8.count <= 1024 && !$0.contains("\0") }) else {
                    throw ConfigBackupError.invalidArchive
                }
            default: throw ConfigBackupError.invalidArchive
            }
        }
        if let credentials {
            guard credentials.count <= 264, credentials.keys.allSatisfy(isCredentialAccount),
                  credentials.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16384 && !$0.contains("\0") })
            else { throw ConfigBackupError.invalidArchive }
        }
    }

    static func apply(_ values: [String: ConfigBackupValue], sections: Set<ConfigBackupSection>,
                      preservingMissingKeys: Set<String> = [], to defaults: UserDefaults) throws {
        try validate(values)
        for (key, entry) in entries where sections.contains(entry.section) {
            if let value = values[key] { defaults.set(value.propertyListValue, forKey: key) }
            else if !preservingMissingKeys.contains(key) {
                if key == aiRoutingKey {
                    // A reset must stay Not set after launch; removing this
                    // marker would re-run migration from the frozen old tab.
                    let empty = AIRoutingState(routes: [:], migratedRoutes: [:], servers: [], migrationVersion: 1)
                    defaults.set(try JSONEncoder().encode(empty), forKey: key)
                } else { defaults.removeObject(forKey: key) }
            }
        }
        guard defaults.synchronize() else { throw ConfigBackupError.restoreFailed }
    }
}
