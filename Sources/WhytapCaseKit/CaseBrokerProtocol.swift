import Foundation

/// Wire protocol between the `whytap` CLI / MCP server and the app's Case
/// broker: newline-delimited JSON over a Unix socket, one request per
/// connection. Secret values only ever appear in `runEnvironment` responses.
public enum CaseBrokerRequest: Codable, Equatable {
    /// Non-secret, allowlisted application controls. Separate from Case authority.
    case appControl(AppControlRequest)
    case listProjects
    case listKeys(project: String?)
    case resolveRun(project: String?, only: [String]?, command: String, cwd: String)
}

public struct CaseProjectInfo: Codable, Equatable {
    public let name: String
    public let description: String
    public let keyCount: Int

    public init(name: String, description: String, keyCount: Int) {
        self.name = name
        self.description = description
        self.keyCount = keyCount
    }
}

public struct CaseKeyInfo: Codable, Equatable {
    public let name: String
    public let description: String
    public let project: String

    public init(name: String, description: String, project: String) {
        self.name = name
        self.description = description
        self.project = project
    }
}

public enum CaseDenyReason: String, Codable, Equatable {
    case notRegistered, unknownAIApp, userDeclined, timedOut, touchIDFailed
    case unknownProject, unknownKey, untrustedHelper, vaultUnavailable
}

public enum CaseBrokerResponse: Codable, Equatable {
    case appControl(AppControlResponse)
    case projects([CaseProjectInfo])
    case keys([CaseKeyInfo])
    /// Only for `resolveRun`.
    case runEnvironment([String: String])
    case ambiguous(key: String, projects: [CaseProjectInfo])
    case denied(reason: CaseDenyReason)
}

/// One message = one line of JSON terminated by `\n`.
public enum CaseBrokerCodec {
    public static func encodeLine<T: Encodable>(_ message: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    public static func decodeLine<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        var body = line
        while let last = body.last, last == 0x0A || last == 0x0D { body.removeLast() }
        return try JSONDecoder().decode(type, from: body)
    }
}

public enum CaseBrokerPaths {
    /// `sockaddr_un.sun_path` holds 104 bytes on macOS including the NUL.
    public static let maxSocketPathBytes = 103

    /// `~/Library/Application Support/<bundleID>/case-broker.sock`, or the
    /// shorter `cb.sock` when the home directory is long enough that the
    /// full name would not fit in `sun_path`.
    public static func socketURL(bundleID: String) -> URL {
        socketURL(bundleID: bundleID, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public static func socketURL(bundleID: String, home: URL) -> URL {
        let dir = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
        let preferred = dir.appendingPathComponent("case-broker.sock")
        if preferred.path.utf8.count <= maxSocketPathBytes { return preferred }
        return dir.appendingPathComponent("cb.sock")
    }
}
