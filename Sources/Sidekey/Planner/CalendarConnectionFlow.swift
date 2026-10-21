import SwiftUI

/// The permission operation outlives an inline view temporarily hidden by a
/// meeting/agent surface. Explicit Cancel ends it; Settings sheets cancel on close.
@MainActor
final class CalendarConnectionFlow: ObservableObject {
    typealias Authorization = (CalendarProvider, String, String, String) async throws -> (code: String, redirect: String)
    @Published private(set) var working = false
    @Published private(set) var error: String?
    private(set) var lastProvider: CalendarProvider?
    private let connections: CalendarConnections
    private let activityChanged: (Bool) -> Void
    private let authorize: Authorization?
    private var browser: CalendarBrowserSignIn?
    private var task: Task<Void, Never>?

    init(connections: CalendarConnections, activityChanged: @escaping (Bool) -> Void = { _ in },
         authorize: Authorization? = nil) {
        self.connections = connections; self.activityChanged = activityChanged; self.authorize = authorize
    }

    func clearError() { error = nil }
    func cancel() { error = nil; task?.cancel(); browser?.cancel() }

    @discardableResult
    func start(provider: CalendarProvider, clientID: String, secret: String, label: String,
               info: [String: Any]?, onSuccess: @escaping () -> Void) -> Bool {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working, CalendarConnectionReadiness.authorization(provider, clientID: clientID, info: info) == .available,
              provider == .apple || connections.accountConnectionIssue == nil,
              connections.beginConnecting(provider: provider) else { return false }
        working = true; error = nil; lastProvider = provider; activityChanged(true)
        let browser = CalendarBrowserSignIn(configurationInfo: info)
        self.browser = browser
        task = Task {
            defer {
                self.browser = nil; self.task = nil; working = false
                connections.endConnecting(); activityChanged(false)
            }
            do {
                if provider == .apple { try await connections.enableApple() }
                else {
                    let id = UUID()
                    let verifier = try CalendarPKCE.random()
                    let state = try CalendarPKCE.random()
                    let result: (code: String, redirect: String)
                    if let authorize { result = try await authorize(provider, clientID, state, verifier) }
                    else { result = try await browser.authorize(provider: provider, clientID: clientID, state: state, verifier: verifier) }
                    try Task.checkCancellation()
                    try await connections.oauth.connect(provider: provider, clientID: clientID, clientSecret: secret,
                        code: result.code, redirect: result.redirect, verifier: verifier, id: id)
                    do {
                        try Task.checkCancellation()
                        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        try connections.add(ConnectedCalendarAccount(id: id, provider: provider,
                            label: name.isEmpty ? provider.title : String(name.prefix(120))))
                    } catch { try? await connections.oauth.disconnect(id); throw error }
                }
                try Task.checkCancellation()
                onSuccess()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? CalendarConnectionError)?.localizedDescription ?? "Couldn’t connect the calendar. Try again."
            }
        }
        return true
    }
}
