/// In-memory presentation of the state supplied by the island. Resolving a
/// capsule never reads stores or invents an enabled state for navigation tools.
struct HoverToolPresentation: Equatable {
    let title: String
    let status: String?

    static func resolve(
        tool: HoverTool,
        mode: TranscriptionMode,
        inputLanguage: AppLanguage?,
        outputLanguage: AppLanguage?,
        meetingRecordingActive: Bool
    ) -> Self {
        let status: String?
        switch tool {
        case .dropMode:
            status = mode == .fast ? "Fast" : "Smart"
        case .inputLang:
            status = inputLanguage?.displayName ?? "Auto"
        case .outputLang:
            status = mode == .fast ? "Smart only" : (outputLanguage?.displayName ?? "Off")
        case .meetingRecord:
            status = meetingRecordingActive ? "Recording" : "Not recording"
        case .clipboard, .notifs, .vocab, .caseVault, .filler, .hotkeys, .notes, .monitor, .quit, .settings:
            status = nil
        }
        return Self(title: HoverToolRegistry.info(for: tool).title, status: status)
    }
}
