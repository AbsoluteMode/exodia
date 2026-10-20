import Foundation
import WhytapCaseKit

/// Who is asking the broker for keys, as established by caller resolution.
enum CaseCaller: Equatable {
    case registered(CaseAppRegistration)
    case knownUnregisteredAI(name: String)
    case human
}

enum CaseAccessDecision: Equatable {
    case allow
    case askApproval
    case askTouchID
    case deny(CaseDenyReason)
}

/// In-memory "allow for N minutes" grants, keyed by (app, project).
/// Never persisted: quitting or relaunching Whytap forgets them. The panel's
/// idle lock does not, because the broker keeps serving while the panel is
/// locked; a grant simply runs out at its time.
struct CaseTimedGrants: Equatable {
    private var expiry: [Key: Date] = [:]

    private struct Key: Hashable {
        let appID: UUID
        let projectID: UUID
    }

    mutating func grant(appID: UUID, projectID: UUID, until: Date) {
        expiry[Key(appID: appID, projectID: projectID)] = until
    }

    /// Active strictly before `until`.
    func isGranted(appID: UUID, projectID: UUID, now: Date) -> Bool {
        guard let until = expiry[Key(appID: appID, projectID: projectID)] else { return false }
        return now < until
    }

    mutating func removeAll() { expiry.removeAll() }

    mutating func remove(appID: UUID) {
        expiry = expiry.filter { $0.key.appID != appID }
    }
}

/// Pure access rules. No I/O, no clock of its own.
enum CaseAccessPolicy {
    /// Listing names and descriptions never asks for approval: a registered
    /// app is allowed, a person proves presence with Touch ID, an
    /// unregistered known AI app is refused outright.
    static func decideList(caller: CaseCaller) -> CaseAccessDecision {
        switch caller {
        case .registered: return .allow
        case .human: return .askTouchID
        case .knownUnregisteredAI: return .deny(.unknownAIApp)
        }
    }

    static func decideRun(
        caller: CaseCaller,
        projectID: UUID,
        grants: CaseTimedGrants,
        now: Date
    ) -> CaseAccessDecision {
        switch caller {
        case .human:
            return .askTouchID
        case .knownUnregisteredAI:
            return .deny(.unknownAIApp)
        case .registered(let app):
            guard app.allows(projectID: projectID) else { return .deny(.unknownProject) }
            let mode = app.projectModes[projectID] ?? app.defaultMode
            switch mode {
            case .bypass:
                return .allow
            case .approve:
                return grants.isGranted(appID: app.id, projectID: projectID, now: now) ? .allow : .askApproval
            }
        }
    }
}
