import Foundation
@testable import Sidekey

final class BackupGitHubFixture {
    let json: (Any) -> Data
    var tag: String?
    var draft = true
    var corruptReadback = false
    var failOneReadback = false
    var publishCount = 0
    var uploadNames: [String] = []
    var assets: [[String: Any]] = []
    var bytes: [Int: Data] = [:]
    init(json: @escaping (Any) -> Data) { self.json = json }
    func release() -> Data {
        json(["id": 7, "tag_name": tag!, "draft": draft, "body": "exodia.encrypted-backup.v1",
              "created_at": "2026-10-19T12:00:00Z", "assets": assets])
    }
    func handle(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        let path = request.url!.path, method = request.httpMethod!
        if path == "/user" { return (200, [:], json(["login": "developer"])) }
        if path.hasSuffix("/Exodia-Backup") { return (200, [:], json(["name": "Exodia-Backup", "private": true])) }
        if path.contains("/releases/tags/") { return tag == nil || draft ? (404, [:], Data()) : (200, [:], release()) }
        if path.hasSuffix("/releases"), method == "GET" {
            return (200, [:], json(tag == nil ? [] : [try JSONSerialization.jsonObject(with: release())]))
        }
        if path.contains("/releases/assets/"), method == "DELETE" {
            let id = Int(path.components(separatedBy: "/").last!)!
            assets.removeAll { ($0["id"] as? Int) == id }; bytes.removeValue(forKey: id)
            return (204, [:], Data())
        }
        if path.hasSuffix("/releases"), method == "POST" {
            let body = try JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies.last!) as! [String: Any]
            tag = body["tag_name"] as? String
            return (201, [:], release())
        }
        if request.url!.host == "uploads.github.com" {
            let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
            let data = StubURLProtocol.capturedBodies.last!, id = assets.count + 100
            let asset: [String: Any] = ["id": id, "name": name, "size": data.count, "state": "uploaded"]
            assets.append(asset); bytes[id] = data; uploadNames.append(name)
            return (201, [:], json(asset))
        }
        if path.contains("/releases/assets/") {
            let id = Int(path.components(separatedBy: "/").last!)!
            let data = bytes[id]!
            if failOneReadback { failOneReadback = false; throw URLError(.networkConnectionLost) }
            return (200, ["Content-Type": "application/octet-stream"], corruptReadback ? Data(repeating: 0, count: data.count) : data)
        }
        if path.hasSuffix("/releases/7"), method == "PATCH" { draft = false; publishCount += 1; return (200, [:], release()) }
        if path.hasSuffix("/releases/7") { return (200, [:], release()) }
        throw URLError(.badURL)
    }
}
