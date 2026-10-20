import AppKit
import CryptoKit
import Network
import Security

struct CalendarCredential: Codable {
    var provider: CalendarProvider
    var clientID: String
    var clientSecret: String?
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

protocol CalendarCredentialStorage: Sendable {
    func read(_ id: UUID) throws -> CalendarCredential?
    func save(_ credential: CalendarCredential, id: UUID) throws
    func delete(_ id: UUID) throws
}

struct CalendarKeychain: CalendarCredentialStorage {
    static func account(_ id: UUID) -> String { "calendar.\(id.uuidString)" }
    private func store(_ id: UUID) -> KeychainStore { KeychainStore(account: Self.account(id)) }
    func read(_ id: UUID) throws -> CalendarCredential? {
        guard let text = try store(id).read(), let data = text.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(CalendarCredential.self, from: data)
    }
    func save(_ credential: CalendarCredential, id: UUID) throws {
        try store(id).save(String(decoding: JSONEncoder().encode(credential), as: UTF8.self))
        Task { @MainActor in NotificationCenter.default.post(name: .exodiaBackupArtifactsChanged, object: nil) }
    }
    func delete(_ id: UUID) throws {
        try store(id).delete()
        Task { @MainActor in NotificationCenter.default.post(name: .exodiaBackupArtifactsChanged, object: nil) }
    }
}

enum CalendarPKCE {
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CalendarConnectionError.configuration
        }
        return encode(Data(bytes))
    }
    static func challenge(_ verifier: String) -> String { encode(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(provider: CalendarProvider, clientID: String,
        redirect: String, state: String, verifier: String) throws -> URL {
        guard provider != .apple, !clientID.isEmpty,
              var components = URLComponents(string: provider.authorizationEndpoint) else {
            throw CalendarConnectionError.configuration
        }
        var values = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code",
            "scope": provider.scopes, "state": state, "code_challenge": challenge(verifier),
            "code_challenge_method": "S256"]
        if provider == .google { values["access_type"] = "offline"; values["prompt"] = "consent" }
        if provider == .microsoft { values["prompt"] = "select_account" }
        components.queryItems = values.sorted { $0.key < $1.key }.map(URLQueryItem.init(name:value:))
        guard let url = components.url else { throw CalendarConnectionError.configuration }
        return url
    }

    static func callback(_ target: String, expectedState: String) throws -> String {
        guard let components = URLComponents(string: "http://127.0.0.1" + target),
              components.path == "/callback" else { throw CalendarConnectionError.configuration }
        let items = components.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw CalendarConnectionError.configuration
        }
        if items.contains(where: { $0.name == "error" }) { throw CalendarConnectionError.denied }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw CalendarConnectionError.configuration
        }
        return code
    }
}

/// Temporary HTTP receiver bound only to loopback. No application backend or custom URL handler.
@MainActor
final class CalendarBrowserSignIn {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<(code: String, redirect: String), Error>?
    private var timeout: DispatchWorkItem?
    private var connections: [UUID: NWConnection] = [:]
    private let openBrowser: (URL) -> Bool
    private let timeoutSeconds: Double
    private var expectedRedirect: String?

    init(timeoutSeconds: Double = 180, openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.timeoutSeconds = timeoutSeconds
        self.openBrowser = openBrowser
    }

    func authorize(provider: CalendarProvider, clientID: String, state: String,
        verifier: String) async throws -> (code: String, redirect: String) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self, weak listener] status in
                        Task { @MainActor in
                            guard let self, self.continuation != nil else { return }
                            switch status {
                            case .ready:
                                guard let port = listener?.port else { self.finish(.failure(CalendarConnectionError.configuration)); return }
                                // Entra's documented ephemeral-port exception applies to localhost.
                                // The listener still binds only the numeric IPv4 loopback interface.
                                let host = provider == .microsoft ? "localhost" : "127.0.0.1"
                                let redirect = "http://\(host):\(port.rawValue)/callback"
                                self.expectedRedirect = redirect
                                do {
                                    let url = try CalendarPKCE.authorizationURL(provider: provider, clientID: clientID,
                                        redirect: redirect, state: state, verifier: verifier)
                                    guard self.openBrowser(url) else { throw CalendarConnectionError.unavailable }
                                } catch { self.finish(.failure(error)) }
                            case .failed: self.finish(.failure(CalendarConnectionError.unavailable))
                            default: break
                            }
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor in
                            guard let self, self.continuation != nil, self.connections.count < 8 else { connection.cancel(); return }
                            let id = UUID()
                            self.connections[id] = connection
                            connection.start(queue: .main)
                            self.receive(connection, id: id, data: Data(), state: state)
                        }
                    }
                    let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(CalendarConnectionError.timeout)) }
                    self.timeout = timeout
                    DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
                    listener.start(queue: .main)
                } catch { self.finish(.failure(CalendarConnectionError.unavailable)) }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func cancel() { finish(.failure(CalendarConnectionError.cancelled)) }

    private func receive(_ connection: NWConnection, id: UUID, data: Data, state: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] next, _, ended, error in
            Task { @MainActor in
                guard let self, self.continuation != nil else { connection.cancel(); return }
                let data = data + (next ?? Data())
                guard data.count <= 16_384, error == nil else { self.close(id); return }
                guard let request = String(data: data, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if ended { self.close(id) } else { self.receive(connection, id: id, data: data, state: state) }
                    return
                }
                let line = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard line.count == 3, line[0] == "GET", let redirect = self.expectedRedirect else { self.close(id); return }
                let result: Result<(code: String, redirect: String), Error>
                do { result = .success((try CalendarPKCE.callback(String(line[1]), expectedState: state), redirect)) }
                catch CalendarConnectionError.denied { result = .failure(CalendarConnectionError.denied) }
                catch { self.close(id); return } // Ignore unrelated requests without ending the pending sign-in.
                let html = "<!doctype html><meta charset=utf-8><title>Whytap</title><p>You can return to Whytap and close this tab.</p>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
                self.connections.removeValue(forKey: id)
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                self.finish(result)
            }
        }
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
    private func finish(_ result: Result<(code: String, redirect: String), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        expectedRedirect = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        continuation.resume(with: result)
    }
}

actor CalendarOAuthClient {
    private let http: CalendarHTTP
    private let storage: any CalendarCredentialStorage
    private var refreshes: [UUID: Task<CalendarCredential, Error>] = [:]
    private var removed: Set<UUID> = []

    init(http: CalendarHTTP = CalendarHTTP(), storage: any CalendarCredentialStorage = CalendarKeychain()) {
        self.http = http; self.storage = storage
    }

    func connect(provider: CalendarProvider, clientID: String, clientSecret: String?, code: String,
        redirect: String, verifier: String, id: UUID) async throws {
        var values = ["client_id": clientID, "grant_type": "authorization_code", "code": code,
            "redirect_uri": redirect, "code_verifier": verifier]
        if provider == .google, let clientSecret, !clientSecret.isEmpty { values["client_secret"] = clientSecret }
        let credential = try await exchange(provider: provider, clientID: clientID, clientSecret: clientSecret,
            values: values, previousRefresh: nil)
        try Task.checkCancellation()
        guard !removed.contains(id) else { throw CancellationError() }
        do { try storage.save(credential, id: id) } catch { throw CalendarConnectionError.keychain }
    }

    func accessToken(_ id: UUID, forceRefresh: Bool = false, expectedProvider: CalendarProvider? = nil) async throws -> String {
        guard !removed.contains(id) else { throw CalendarConnectionError.signInRequired }
        let credential: CalendarCredential
        do {
            guard let value = try storage.read(id) else { throw CalendarConnectionError.signInRequired }
            credential = value
        } catch let error as CalendarConnectionError { throw error }
        catch { throw CalendarConnectionError.keychain }
        if let expectedProvider, credential.provider != expectedProvider { throw CalendarConnectionError.configuration }
        if !forceRefresh, credential.expiresAt.timeIntervalSinceNow > 90 { return credential.accessToken }
        if let existing = refreshes[id] { return try await existing.value.accessToken }
        let task = Task<CalendarCredential, Error> {
                defer { self.refreshes[id] = nil }
                var values = ["client_id": credential.clientID, "grant_type": "refresh_token", "refresh_token": credential.refreshToken]
                if credential.provider == .google, let secret = credential.clientSecret, !secret.isEmpty { values["client_secret"] = secret }
                let updated = try await self.exchange(provider: credential.provider, clientID: credential.clientID,
                    clientSecret: credential.clientSecret, values: values, previousRefresh: credential.refreshToken)
                try Task.checkCancellation()
                guard !self.removed.contains(id) else { throw CancellationError() }
                do { try self.storage.save(updated, id: id) } catch { throw CalendarConnectionError.keychain }
                return updated
        }
        refreshes[id] = task
        let updated = try await task.value
        try Task.checkCancellation()
        guard !removed.contains(id) else { throw CancellationError() }
        return updated.accessToken
    }

    func disconnect(_ id: UUID) throws {
        removed.insert(id)
        refreshes.removeValue(forKey: id)?.cancel()
        do { try storage.delete(id) } catch { removed.remove(id); throw CalendarConnectionError.keychain }
    }

    private func exchange(provider: CalendarProvider, clientID: String, clientSecret: String?,
        values: [String: String], previousRefresh: String?) async throws -> CalendarCredential {
        guard provider != .apple, let url = URL(string: provider.tokenEndpoint) else { throw CalendarConnectionError.configuration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CalendarHTTP.form(values)
        let result: [String: Any]
        do { result = try await http.json(request) }
        catch CalendarConnectionError.http(400) { throw CalendarConnectionError.signInRequired }
        guard let access = result["access_token"] as? String, !access.isEmpty,
              let refresh = (result["refresh_token"] as? String) ?? previousRefresh, !refresh.isEmpty,
              let expires = result["expires_in"] as? Double, expires > 0,
              (result["token_type"] as? String)?.lowercased() == "bearer" else { throw CalendarConnectionError.invalidResponse }
        return CalendarCredential(provider: provider, clientID: clientID, clientSecret: clientSecret,
            accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expires))
    }
}
