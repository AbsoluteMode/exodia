// Sources/Sidekey/Settings/WhytapLink.swift
import Foundation

/// The place a `whytap://` link shows. Any web page can open a link, so a
/// link only shows where a feature lives: it never records, captures,
/// toggles a mode, changes a setting, copies, pastes, authenticates or quits.
/// Action tools open their own window or their Toolbox pane, whose button
/// stays explicit. Add a case only if it is show-only (Invariant 7).
/// WHY: .project-docs/decisions/2026-10-20-whytap-links.md
enum WhytapLinkDestination: Equatable {
    /// Expand the island and open this inline hover panel.
    case hoverPanel(HoverInlinePanel)
    /// Open Settings and highlight this sidebar tab or the Quit row.
    case settings(HoverNavigationTarget)
    /// Open Settings -> Toolbox with this tool's pane selected.
    case toolboxTool(HoverTool)
    case planner(PlannerSection)
    case translation(TranslationWindowController.Mode)
    /// A well-formed link to something this version does not have (a newer
    /// tile, tab or link kind): only show the island.
    case island
}

/// Parses `whytap://tool/<HoverTool rawValue>` and
/// `whytap://settings/<SettingsWindowTab rawValue>`. The enums themselves are
/// the registry of linkable places: both switches below are exhaustive, so a
/// new tile or tab does not compile until it has a destination.
enum WhytapLink {
    static let scheme = "whytap"

    /// `nil` rejects the URL: another scheme, no kind, an empty or nested
    /// path, or an id with characters no enum raw value uses (`..`, `%2F`).
    static func destination(for url: URL) -> WhytapLinkDestination? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.user == nil, components.password == nil, components.port == nil,
              let kind = components.host?.lowercased(), !kind.isEmpty
        else { return nil }

        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2, segments[0].isEmpty else { return nil }
        let id = String(segments[1])
        guard !id.isEmpty, id.count <= 64,
              id.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else { return nil }

        switch kind {
        case "tool":
            return HoverTool(rawValue: id).map(destination(for:)) ?? .island
        case "settings":
            return SettingsWindowTab(rawValue: id).map(destination(for:)) ?? .island
        default:
            return .island
        }
    }

    static func destination(for tool: HoverTool) -> WhytapLinkDestination {
        switch tool {
        case .clipboard: return .hoverPanel(.history)
        case .notifs: return .hoverPanel(.notifications)
        case .vocab: return .hoverPanel(.vocabularyEditor)
        // Both Case surfaces request Touch ID on appear; a link must not
        // prompt. Toolbox lists Case in its catalog for the user to click.
        case .caseVault: return .settings(.tab(.toolbox))
        case .filler: return .hoverPanel(.fillerEditor)
        case .inputLang: return .hoverPanel(.inputLanguagePicker)
        case .outputLang: return .hoverPanel(.outputLanguagePicker)
        case .monitor: return .hoverPanel(.monitor)
        case .brightness: return .hoverPanel(.brightness)
        case .hotkeys: return .settings(.tab(.hotkeys))
        case .notes: return .settings(.tab(.notes))
        // Highlights the Quit row; quitting needs the user's click.
        case .quit: return .settings(.quitRow)
        case .settings: return .settings(.tab(.apiAndModels))
        case .tasks: return .hoverPanel(.tasks)
        case .calendar: return .planner(.calendar)
        case .translate: return .translation(.text)
        // The window opens idle; subtitles start from its own button.
        case .subtitles: return .translation(.subtitles)
        // Toolbox shows the pane; the mode switch, recording and capture
        // stay behind its explicit buttons.
        case .dropMode, .meetingRecord, .screenshot: return .toolboxTool(tool)
        }
    }

    static func destination(for tab: SettingsWindowTab) -> WhytapLinkDestination {
        switch tab {
        case .apiAndModels, .hotkeys, .permissions, .notes, .agentMode, .toolbox,
             .notifications, .integrations, .backup, .other:
            return .settings(.tab(tab))
        }
    }
}
