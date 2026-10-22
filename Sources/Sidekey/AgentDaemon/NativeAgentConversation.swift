import Foundation

/// Only completed text pairs survive a turn. Screenshots, tool arguments/results
/// and provider reasoning remain in the in-flight request, never in this file.
struct NativeAgentConversation: Codable {
    struct Pair: Codable { let user: String; let assistant: String }
    var id: String
    var route: String
    var updatedAt: Date
    var pairs: [Pair]
    static let fileName = "native-conversation.json"
    static let maximumCharacters = 12_000

    static func load(directory: URL, resumeID: String?, route: String, now: Date = Date()) -> Self {
        let url = directory.appendingPathComponent(fileName)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 100_000,
           let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Self.self, from: data),
           stored.id == resumeID, stored.route == route, now.timeIntervalSince(stored.updatedAt) >= 0,
           now.timeIntervalSince(stored.updatedAt) < AgentSessionStore.resumeWindow {
            var bounded = stored
            bounded.trim()
            return bounded
        }
        return Self(id: UUID().uuidString, route: route, updatedAt: now, pairs: [])
    }

    mutating func append(user: String, assistant: String, directory: URL, now: Date = Date()) throws {
        pairs.append(Pair(user: user, assistant: assistant)); updatedAt = now
        trim()
        let data = try JSONEncoder().encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    private mutating func trim() {
        while pairs.count > 6 || pairs.reduce(0, { $0 + $1.user.count + $1.assistant.count }) > Self.maximumCharacters {
            pairs.removeFirst()
        }
    }
}
