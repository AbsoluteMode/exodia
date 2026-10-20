enum SettingsWindowTab: String, CaseIterable, Identifiable {
    case apiAndModels
    case hotkeys
    case permissions
    case notes
    case agentMode
    case toolbox
    case notifications
    case integrations
    case backup
    case other

    var id: String { rawValue }

    static var availableCases: [SettingsWindowTab] {
        allCases
    }

    static var defaultAvailable: SettingsWindowTab {
        availableCases.first ?? .apiAndModels
    }

    var isAvailable: Bool {
        Self.availableCases.contains(self)
    }

    var title: String {
        switch self {
        case .apiAndModels:
            return "API & Models"
        case .hotkeys:
            return "Hotkeys"
        case .permissions:
            return "Permissions"
        case .notes:
            return "Meetings"
        case .agentMode:
            return "Agents"
        case .toolbox:
            return "Toolbox"
        case .notifications:
            return "Notifications"
        case .integrations:
            return "Integrations"
        case .backup:
            return "Backup"
        case .other:
            return "Other"
        }
    }

    var systemImageName: String {
        fallbackSystemImageName
    }

    var fallbackSystemImageName: String {
        switch self {
        case .apiAndModels:
            return "cpu"
        case .hotkeys:
            return "keyboard"
        case .permissions:
            return "checkmark.shield.fill"
        case .notes:
            return "note.text"
        case .agentMode:
            return "bolt.horizontal.circle.fill"
        case .toolbox:
            return "square.grid.2x2"
        case .notifications:
            return "bell.badge"
        case .integrations:
            return "puzzlepiece.extension"
        case .backup:
            return "externaldrive.badge.timemachine"
        case .other:
            return "ellipsis.circle"
        }
    }

    var pdfResourceName: String? {
        switch self {
        case .apiAndModels, .hotkeys, .permissions, .notes, .agentMode, .toolbox, .notifications, .integrations, .backup, .other:
            return nil
        }
    }
}
