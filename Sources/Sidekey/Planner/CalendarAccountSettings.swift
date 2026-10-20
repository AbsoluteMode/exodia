import Foundation

/// The live store and the encrypted backup use the same bounded account document.
enum CalendarAccountSettings {
    static let accountsKey = "planner.calendar.accounts.v1"
    static let hiddenFeedsKey = "planner.calendar.hiddenFeeds"
    static let appleEnabledKey = "planner.calendar.appleEnabled"
    static let keys: Set<String> = [accountsKey, hiddenFeedsKey, appleEnabledKey]

    static func decode(_ data: Data) throws -> [ConnectedCalendarAccount] {
        guard data.count <= 128 * 1024 else { throw CalendarConnectionError.configuration }
        let accounts = try JSONDecoder().decode([ConnectedCalendarAccount].self, from: data)
        guard accounts.count <= 64, Set(accounts.map(\.id)).count == accounts.count,
              accounts.allSatisfy({ $0.provider != .apple && !$0.label.isEmpty && $0.label.count <= 120 }) else {
            throw CalendarConnectionError.configuration
        }
        return accounts
    }
}

struct CalendarClientConfiguration: Equatable {
    var clientID: String
    var clientSecret: String?

    /// Public native-client configuration, supplied by the app owner when packaging.
    /// User access/refresh tokens never belong in this dictionary.
    static func registered(_ provider: CalendarProvider, info: [String: Any]? = Bundle.main.infoDictionary) -> Self? {
        guard provider != .apple,
              let clients = info?["WhytapCalendarOAuthClients"] as? [String: [String: String]],
              let client = clients[provider.rawValue], let id = client["clientID"],
              !id.isEmpty, id.utf8.count <= 8192, !id.contains(where: { $0.isWhitespace || $0 == "\0" }) else { return nil }
        // Google desktop clients are public clients; their generated client secret
        // is public native-app configuration, not a confidential web-app secret.
        let secret = provider == .google ? client["clientSecret"] : nil
        guard (secret?.utf8.count ?? 0) <= 8192 else { return nil }
        return Self(clientID: id, clientSecret: secret)
    }
}
