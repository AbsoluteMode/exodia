import Foundation

enum ConfigBackupSection: String, Codable, CaseIterable, Identifiable {
    case models, hotkeys, vocabulary, toolbox, other, agents, credentials
    var id: String { rawValue }
    var title: String {
        switch self {
        case .models: return "Models & languages"
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
    enum Kind { case string, bool, strings }
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
        + ["byok.openrouter.llm_api_key", "byok.custom_llm.api_key"])

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
            case (.strings, .strings(let values)):
                guard values.count <= 256, values.allSatisfy({ $0.utf8.count <= 1024 && !$0.contains("\0") }) else {
                    throw ConfigBackupError.invalidArchive
                }
            default: throw ConfigBackupError.invalidArchive
            }
        }
        if let credentials {
            guard Set(credentials.keys).isSubset(of: credentialAccounts),
                  credentials.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16384 && !$0.contains("\0") })
            else { throw ConfigBackupError.invalidArchive }
        }
    }

    static func apply(_ values: [String: ConfigBackupValue], sections: Set<ConfigBackupSection>, to defaults: UserDefaults) throws {
        try validate(values)
        for (key, entry) in entries where sections.contains(entry.section) {
            if let value = values[key] { defaults.set(value.propertyListValue, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        guard defaults.synchronize() else { throw ConfigBackupError.restoreFailed }
    }
}
