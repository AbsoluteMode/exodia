import Combine
import Foundation

/// App-owned source: no script, provider setup or system notification permission.
// WHY: .project-docs/decisions/2026-10-20-meeting-ready-notifications.md
@MainActor
final class MeetingReadyNotifications: ObservableObject {
    static let shared = MeetingReadyNotifications(defaults: .standard, hub: .shared)
    static let sourceID = "builtin.meeting-ready"
    private static let enabledKey = "notifications.meetingReady.enabled"

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    private let defaults: UserDefaults
    private let hub: LocalNotificationHub

    init(defaults: UserDefaults, hub: LocalNotificationHub) {
        self.defaults = defaults
        self.hub = hub
        // Absence means ON for both existing installations and new users.
        // Never overwrite a user's explicit OFF when the app starts again.
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    @discardableResult
    func receive(_ event: MeetingsCoordinatorEvent) async -> Bool {
        guard enabled, case .newMeetingAvailable(let id) = event else { return false }
        return await hub.receive(LocalNotificationEvent(
            id: Self.sourceID + ":" + id.uuidString,
            source: Self.sourceID, sourceName: "Meeting notes",
            title: "Meeting notes are ready", body: "Click to open your meeting notes.",
            link: nil, timestamp: Date(), customTint: "#785EFF", customLogo: "whytap",
            meetingID: id
        ))
    }
}
