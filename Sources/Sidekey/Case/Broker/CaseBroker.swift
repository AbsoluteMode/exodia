import Darwin
import Foundation
import WhytapCaseKit

// MARK: Approval prompt seam (implemented by Task 10's island prompt)

struct CaseApprovalRequest: Equatable {
    let appName: String
    let projectName: String
    let keyNames: [String]
    /// Shown to the person only; never logged.
    let command: String
    let timedMinutes: Int
}

enum CaseApprovalOutcome: Equatable {
    case allow, allowTimed, deny, timedOut
}

@MainActor
protocol CaseApprovalPresenting: AnyObject {
    func requestApproval(_ r: CaseApprovalRequest) async -> CaseApprovalOutcome
}

/// Stand-in until the island prompt exists: every Approve request is denied,
/// so nothing runs without a person's decision.
@MainActor
final class CaseDenyingApprovalPresenter: CaseApprovalPresenting {
    func requestApproval(_ r: CaseApprovalRequest) async -> CaseApprovalOutcome { .deny }
}

// MARK: Caller resolution seam

protocol CaseCallerResolving {
    func resolve(peerPID: pid_t, registrations: [CaseAppRegistration]) -> CaseCaller
}

/// Builds a `CaseCallerResolver` per request so registration changes apply
/// immediately.
struct CaseSystemCallerResolver: CaseCallerResolving {
    let inspector: CaseProcessInspecting
    var builtInOpenCodePIDs: () -> Set<pid_t> = { [] }

    func resolve(peerPID: pid_t, registrations: [CaseAppRegistration]) -> CaseCaller {
        CaseCallerResolver(
            inspector: inspector, registrations: registrations,
            builtInOpenCodePIDs: builtInOpenCodePIDs()
        ).resolve(peerPID: peerPID)
    }
}

// MARK: Broker

/// Answers one already-authenticated helper request: who is asking, what the
/// access policy says, and — only for an allowed `resolveRun` — the values of
/// exactly the requested project's keys. Never logs requests, names or values.
@MainActor
final class CaseBroker {
    static func touchIDRunReason(projectName: String) -> String {
        "Терминал хочет использовать ключи проекта \(projectName)"
    }

    static let touchIDListReason = "Терминал хочет посмотреть ключи Case"

    private let service: CaseVaultService
    private let resolver: CaseCallerResolving
    private let approvals: CaseApprovalPresenting
    private let authenticator: CaseAuthenticating
    private let now: () -> Date
    private(set) var grants = CaseTimedGrants()

    init(
        service: CaseVaultService,
        resolver: CaseCallerResolving,
        approvals: CaseApprovalPresenting,
        authenticator: CaseAuthenticating,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.resolver = resolver
        self.approvals = approvals
        self.authenticator = authenticator
        self.now = now
    }

    func handle(_ request: CaseBrokerRequest, peerPID: pid_t) async -> CaseBrokerResponse {
        // The cached payload is reused; never re-read the vault per request.
        guard let payload = try? service.loadIfNeeded() else {
            return .denied(reason: .vaultUnavailable)
        }
        let caller = resolver.resolve(peerPID: peerPID, registrations: payload.apps)

        switch request {
        case .listProjects:
            if let denial = await authorizeListing(caller) { return denial }
            guard let current = service.payload else { return .denied(reason: .vaultUnavailable) }
            return .projects(Self.projectInfos(current.projects, in: current))

        case .listKeys(let projectName):
            if let denial = await authorizeListing(caller) { return denial }
            guard let current = service.payload else { return .denied(reason: .vaultUnavailable) }
            var secrets = current.secrets
            if let projectName {
                guard let project = Self.findProject(projectName, in: current) else {
                    return .denied(reason: .unknownProject)
                }
                secrets = secrets.filter { $0.projectID == project.id }
            }
            let keys = secrets
                .map { CaseKeyInfo(name: $0.name, description: $0.description, project: Self.projectName($0.projectID, current)) }
                .sorted { ($0.project, $0.name) < ($1.project, $1.name) }
            return .keys(keys)

        case let .resolveRun(projectName, only, command, _):
            return await resolveRun(
                caller: caller, payload: payload, projectName: projectName, only: only, command: command)
        }
    }

    // MARK: Run

    private enum Target {
        case resolved(project: CaseProject, secretIDs: [UUID])
        case failure(CaseBrokerResponse)
    }

    private func resolveRun(
        caller: CaseCaller,
        payload: CaseVaultPayload,
        projectName: String?,
        only: [String]?,
        command: String
    ) async -> CaseBrokerResponse {
        // An unregistered AI app learns nothing, not even whether a name exists.
        if case .knownUnregisteredAI = caller { return .denied(reason: .unknownAIApp) }

        let target: (project: CaseProject, secretIDs: [UUID])
        switch Self.target(projectName: projectName, only: only, in: payload) {
        case .resolved(let project, let ids):
            target = (project, ids)
        case .failure(let response):
            // The ambiguity answer names projects and their descriptions; a
            // person at a terminal proves presence first, like for listing.
            if case .ambiguous = response, case .human = caller {
                guard await authenticate(reason: Self.touchIDListReason) else {
                    return .denied(reason: .touchIDFailed)
                }
            }
            return response
        }

        switch CaseAccessPolicy.decideRun(caller: caller, projectID: target.project.id, grants: grants, now: now()) {
        case .allow:
            break
        case .deny(let reason):
            return .denied(reason: reason)
        case .askTouchID:
            guard await authenticate(reason: Self.touchIDRunReason(projectName: target.project.name)) else {
                return .denied(reason: .touchIDFailed)
            }
        case .askApproval:
            guard case .registered(let app) = caller else { return .denied(reason: .notRegistered) }
            let minutes = payload.timedApprovalMinutes
            let request = CaseApprovalRequest(
                appName: app.displayName,
                projectName: target.project.name,
                keyNames: target.secretIDs.compactMap { id in payload.secrets.first { $0.id == id }?.name },
                command: command,
                timedMinutes: minutes)
            switch await approvals.requestApproval(request) {
            case .allow:
                break
            case .allowTimed:
                if minutes > 0 {
                    grants.grant(
                        appID: app.id, projectID: target.project.id,
                        until: now().addingTimeInterval(TimeInterval(minutes) * 60))
                }
            case .deny:
                return .denied(reason: .userDeclined)
            case .timedOut:
                return .denied(reason: .timedOut)
            }
        }

        // The vault may have changed while the prompt was up: read values now,
        // and only for the secrets that were approved.
        guard let current = service.payload else { return .denied(reason: .vaultUnavailable) }
        var environment: [String: String] = [:]
        for id in target.secretIDs {
            guard let secret = current.secrets.first(where: { $0.id == id }),
                  secret.projectID == target.project.id
            else { return .denied(reason: .unknownKey) }
            guard let value = current.value(for: id) else { return .denied(reason: .vaultUnavailable) }
            environment[secret.name] = value
        }
        return .runEnvironment(environment)
    }

    private static func target(projectName: String?, only: [String]?, in payload: CaseVaultPayload) -> Target {
        if let projectName {
            guard let project = findProject(projectName, in: payload) else {
                return .failure(.denied(reason: .unknownProject))
            }
            let inProject = payload.secrets.filter { $0.projectID == project.id }
            guard let only else {
                return .resolved(project: project, secretIDs: inProject.map(\.id))
            }
            var ids: [UUID] = []
            for name in unique(only) {
                guard let secret = inProject.first(where: { $0.name == name }) else {
                    return .failure(.denied(reason: .unknownKey))
                }
                ids.append(secret.id)
            }
            return .resolved(project: project, secretIDs: ids)
        }

        // Without -p a project is never guessed: only named keys are looked up,
        // across all projects, and General is not mixed in.
        guard let only, !only.isEmpty else { return .failure(.denied(reason: .unknownProject)) }
        var ids: [UUID] = []
        var projectID: UUID?
        for name in unique(only) {
            let hits = payload.secrets.filter { $0.name == name }
            if hits.isEmpty { return .failure(.denied(reason: .unknownKey)) }
            if hits.count > 1 {
                let projects = payload.projects.filter { project in hits.contains { $0.projectID == project.id } }
                return .failure(.ambiguous(key: name, projects: projectInfos(projects, in: payload)))
            }
            let hit = hits[0]
            // Keys from different projects in one run would need one decision
            // per project; ask for -p instead.
            if let projectID, projectID != hit.projectID { return .failure(.denied(reason: .unknownProject)) }
            projectID = hit.projectID
            ids.append(hit.id)
        }
        guard let projectID, let project = payload.project(projectID) else {
            return .failure(.denied(reason: .unknownProject))
        }
        return .resolved(project: project, secretIDs: ids)
    }

    // MARK: Helpers

    private func authorizeListing(_ caller: CaseCaller) async -> CaseBrokerResponse? {
        switch CaseAccessPolicy.decideList(caller: caller) {
        case .allow, .askApproval:
            return nil
        case .deny(let reason):
            return .denied(reason: reason)
        case .askTouchID:
            return await authenticate(reason: Self.touchIDListReason) ? nil : .denied(reason: .touchIDFailed)
        }
    }

    private func authenticate(reason: String) async -> Bool {
        do {
            try await authenticator.authenticate(reason: reason)
            return true
        } catch {
            return false
        }
    }

    /// Exact name first; otherwise a single case-insensitive match.
    static func findProject(_ name: String, in payload: CaseVaultPayload) -> CaseProject? {
        if let exact = payload.projects.first(where: { $0.name == name }) { return exact }
        let folded = payload.projects.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return folded.count == 1 ? folded[0] : nil
    }

    private static func projectInfos(_ projects: [CaseProject], in payload: CaseVaultPayload) -> [CaseProjectInfo] {
        projects.map { project in
            CaseProjectInfo(
                name: project.name, description: project.description,
                keyCount: payload.secrets.filter { $0.projectID == project.id }.count)
        }
    }

    private static func projectName(_ id: UUID, _ payload: CaseVaultPayload) -> String {
        payload.project(id)?.name ?? ""
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
}
