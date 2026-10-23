import Foundation

// WHY: .project-docs/decisions/2026-10-21-calendar-integrations.md
extension CalendarProvider {
    var integrationTitle: String { self == .microsoft ? "Outlook Calendar" : title }

    var permissionSummary: String {
        switch self {
        case .google: return "Read your calendar list and events. No access to Gmail or Drive is requested."
        case .microsoft: return "Read calendar events, including Teams meeting links. No email access is requested."
        case .apple: return "Show calendars available on this Mac, including iCloud. macOS asks for full calendar access; Whytap only reads events."
        case .zoom: return "Read Zoom Calendar lists and events. This does not provide access to recordings or meeting transcripts."
        }
    }
}

/// Registration is distinct from approval for public use. Unapproved shared
/// Google/Zoom clients must never lead ordinary users through a warning screen.
enum CalendarConnectionReadiness: Equatable {
    case available, setupRequired, awaitingGoogleVerification, awaitingZoomPublication

    static func shared(_ provider: CalendarProvider,
                       configuration: CalendarClientConfiguration?,
                       googleReview: Bool = GoogleCalendarReviewSession.current.isActive) -> Self {
        if provider == .apple { return .available }
        guard let configuration else { return provider == .zoom ? .awaitingZoomPublication : .setupRequired }
        if provider == .google && !configuration.publicAccessApproved && !googleReview { return .awaitingGoogleVerification }
        if provider == .zoom && !configuration.publicAccessApproved { return .awaitingZoomPublication }
        return .available
    }

    static func authorization(_ provider: CalendarProvider, clientID: String,
                              info: [String: Any]? = Bundle.main.infoDictionary,
                              googleReview: Bool = GoogleCalendarReviewSession.current.isActive) -> Self {
        if provider == .apple { return .available }
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { return .setupRequired }
        let registered = CalendarClientConfiguration.registered(provider, info: info)
        // Development harnesses can explicitly supply their own native client.
        // It is independent of Whytap's shared public registration.
        if registered?.clientID != clientID { return .available }
        return shared(provider, configuration: registered, googleReview: googleReview)
    }

    var status: String {
        switch self {
        case .available: return "Not connected"
        case .setupRequired: return "App setup required"
        case .awaitingGoogleVerification: return "Awaiting Google verification"
        case .awaitingZoomPublication: return "Awaiting Zoom publication"
        }
    }

    var message: String? {
        switch self {
        case .available: return nil
        case .setupRequired: return "This build has no registered calendar client. Install a configured build to connect this calendar."
        case .awaitingGoogleVerification: return "Google verification is not complete. New connections will be available after approval."
        case .awaitingZoomPublication: return "Zoom publication is not complete. New connections will be available after approval."
        }
    }
}
