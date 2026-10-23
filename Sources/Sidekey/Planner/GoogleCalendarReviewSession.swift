import Foundation

/// Explicit, process-local opt-in for recording the real Google verification demo.
/// This permits starting consent; it neither grants access nor approves public use.
// WHY: .project-docs/decisions/2026-10-21-calendar-integrations.md
struct GoogleCalendarReviewSession {
    static let current = Self(environment: ProcessInfo.processInfo.environment)
    static let maximumDuration: TimeInterval = 2 * 60 * 60
    private let startedAt: Date
    private let expiresAt: Date?

    init(environment: [String: String], startedAt: Date = Date()) {
        self.startedAt = startedAt
        guard environment["WHYTAP_GOOGLE_CALENDAR_REVIEW"] == "1",
              let raw = environment["WHYTAP_GOOGLE_CALENDAR_REVIEW_UNTIL"],
              !raw.isEmpty, raw.count <= 20,
              raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let timestamp = TimeInterval(raw), timestamp.isFinite else {
            expiresAt = nil; return
        }
        let expiry = Date(timeIntervalSince1970: timestamp)
        let duration = expiry.timeIntervalSince(startedAt)
        expiresAt = duration.isFinite && duration > 0 && duration <= Self.maximumDuration ? expiry : nil
    }

    var isActive: Bool { isActive(at: Date()) }

    func isActive(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= startedAt && now < expiresAt
    }
}
