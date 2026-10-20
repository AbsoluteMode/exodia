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
    private var releaseID = 7
    private var olderReleases: [String: Data] = [:]
    private var nextAssetID = 100
    var bytes: [Int: Data] = [:]
    init(json: @escaping (Any) -> Data) { self.json = json }
    func release() -> Data {
        json(["id": releaseID, "tag_name": tag!, "draft": draft, "body": "exodia.encrypted-backup.v1",
              "created_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_792_411_200 + Double(releaseID))), "assets": assets])
    }
    func handle(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        let path = request.url!.path, method = request.httpMethod!
        if path == "/user" { return (200, [:], json(["login": "developer"])) }
        if path.hasSuffix("/Exodia-Backup") { return (200, [:], json(["name": "Exodia-Backup", "private": true])) }
        if path.contains("/releases/tags/") {
            let requested = path.components(separatedBy: "/").last!
            if requested == tag, !draft { return (200, [:], release()) }
            return olderReleases[requested].map { (200, [:], $0) } ?? (404, [:], Data())
        }
        if path.hasSuffix("/releases"), method == "GET" {
            var releases = try olderReleases.values.map { try JSONSerialization.jsonObject(with: $0) }
            if tag != nil { releases.append(try JSONSerialization.jsonObject(with: release())) }
            return (200, [:], json(releases))
        }
        if path.contains("/releases/assets/"), method == "DELETE" {
            let id = Int(path.components(separatedBy: "/").last!)!
            assets.removeAll { ($0["id"] as? Int) == id }; bytes.removeValue(forKey: id)
            return (204, [:], Data())
        }
        if path.hasSuffix("/releases"), method == "POST" {
            let body = try JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies.last!) as! [String: Any]
            if let tag { olderReleases[tag] = release(); releaseID += 1 }
            tag = body["tag_name"] as? String
            draft = true; assets = []
            return (201, [:], release())
        }
        if request.url!.host == "uploads.github.com" {
            let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
            let data = StubURLProtocol.capturedBodies.last!, id = nextAssetID
            nextAssetID += 1
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
        if path.hasSuffix("/releases/\(releaseID)"), method == "PATCH" { draft = false; publishCount += 1; return (200, [:], release()) }
        if path.hasSuffix("/releases/\(releaseID)") { return (200, [:], release()) }
        if let saved = olderReleases.values.first(where: {
            let object = try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            return path.hasSuffix("/releases/\(object?["id"] as? Int ?? -1)")
        }) { return (200, [:], saved) }
        throw URLError(.badURL)
    }
}
