import CryptoKit
import XCTest
@testable import Sidekey

final class GitHubBackupTransportTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        super.setUp(); StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() {
        session.invalidateAndCancel(); session = nil; StubURLProtocol.reset(); super.tearDown()
    }
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private func repository(private isPrivate: Bool = true) -> Data {
        json(["name": "Exodia-Backup", "private": isPrivate, "permissions": ["push": true]])
    }

    func testRateLimitedForbiddenResponsesCarryTheirRetryDeadline() async throws {
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        let deadline = Date().addingTimeInterval(3_600)
        for headers in [["Retry-After": "3600"],
                        ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(deadline.timeIntervalSince1970)]] {
            StubURLProtocol.handler = { _ in (403, headers, Data()) }
            do { try await transport.checkConnection(); XCTFail("Expected rate limit") }
            catch {
                guard case .rateLimited(let until) = error as? GitHubBackupTransport.Failure else {
                    XCTFail("Unexpected failure: \(error)"); continue
                }
                XCTAssertGreaterThanOrEqual(until.timeIntervalSince(deadline), -1)
                XCTAssertFalse((error as? GitHubBackupTransport.Failure)!.requiresReconnect)
            }
        }
        StubURLProtocol.handler = { _ in (403, [:], Data()) }
        do { try await transport.checkConnection(); XCTFail("Expected permission failure") }
        catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .permission) }
    }

    func testExplicitDeletionWorksForPublicRepositoryAndIncludesDraftsButKeepsUnrelatedReleases() async throws {
        let kept = UUID(), old = UUID(), draft = UUID()
        func release(_ id: Int, _ tag: String, _ marker: String, draft: Bool = false) -> [String: Any] {
            ["id": id, "draft": draft, "tag_name": tag, "body": marker,
             "created_at": "2026-10-19T12:00:00Z", "assets": []]
        }
        var releases = [
            release(1, "exodia-backup-" + kept.uuidString.lowercased(), "exodia.encrypted-backup.v1"),
            release(2, "exodia-backup-" + old.uuidString.lowercased(), "exodia.encrypted-backup.v1"),
            release(3, "exodia-backup-" + draft.uuidString.lowercased(), "exodia.encrypted-backup.v1", draft: true),
            release(4, "unrelated", "exodia.encrypted-backup.v1"),
            release(5, "exodia-backup-" + UUID().uuidString.lowercased(), "User's release")
        ]
        var deleted: [Int] = []
        StubURLProtocol.handler = { request in
            let path = request.url!.path
            if path == "/repos/developer/Exodia-Backup" { return (200, [:], self.repository(private: false)) }
            if path == "/repos/developer/Exodia-Backup/releases" { return (200, [:], self.json(releases)) }
            guard let id = Int(path.components(separatedBy: "/").last!) else { XCTFail("Unexpected route"); return (500, [:], Data()) }
            if request.httpMethod == "DELETE" {
                deleted.append(id); releases.removeAll { ($0["id"] as? Int) == id }
                return (204, [:], Data())
            }
            return (releases.contains { ($0["id"] as? Int) == id } ? 200 : 404, [:], Data())
        }
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        try await transport.deleteBackups(except: kept)
        XCTAssertEqual(deleted, [2, 3])
        XCTAssertEqual(releases.compactMap { $0["id"] as? Int }, [1, 4, 5])
        try await transport.deleteBackups(except: kept)
        XCTAssertEqual(deleted, [2, 3], "Retry must not delete the replacement or unrelated releases")
        XCTAssertFalse(StubURLProtocol.capturedRequests.contains { $0.httpMethod == "PATCH" || $0.httpMethod == "POST" })
    }

    func testDeletionRequiresAnAbsentReadbackAndDoesNotReportSuccessForAConcurrentUpload() async throws {
        let id = UUID()
        let release: [String: Any] = ["id": 7, "draft": false, "tag_name": "exodia-backup-" + id.uuidString.lowercased(),
            "body": "exodia.encrypted-backup.v1", "created_at": "2026-10-19T12:00:00Z", "assets": []]
        var readbackStatus = 200
        StubURLProtocol.handler = { request in
            if request.url!.path == "/repos/developer/Exodia-Backup" { return (200, [:], self.repository()) }
            if request.url!.path.hasSuffix("/releases") { return (200, [:], self.json([release])) }
            return (request.httpMethod == "DELETE" ? 204 : readbackStatus, [:], Data())
        }
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        do { try await transport.deleteBackups(); XCTFail("A delete response is not proof of removal") }
        catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .incomplete) }
        readbackStatus = 404
        do { try await transport.deleteBackups(); XCTFail("A newly listed copy must keep cleanup pending") }
        catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .incomplete) }
    }

    func testConnectCreatesOnlyAPrivateRepositoryAndChecksTheResult() async throws {
        var seenRepository = false
        StubURLProtocol.handler = { request in
            if request.url!.path == "/user" { return (200, [:], self.json(["login": "developer"])) }
            if request.url!.path == "/user/repos" {
                let body = try JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies.last!) as! [String: Any]
                XCTAssertEqual(body["private"] as? Bool, true)
                XCTAssertEqual(body["auto_init"] as? Bool, true)
                XCTAssertEqual(body["name"] as? String, "Exodia-Backup")
                seenRepository = true
                return (201, [:], self.repository())
            }
            return (seenRepository ? 200 : 404, [:], self.repository())
        }
        let connection = try await GitHubBackupTransport.connect(token: "synthetic-token", session: session)
        let name = await connection.destinationName
        XCTAssertEqual(name, "developer/Exodia-Backup")
        XCTAssertEqual(StubURLProtocol.capturedRequests.map { $0.url!.host! }, Array(repeating: "api.github.com", count: 4))
        XCTAssertFalse(StubURLProtocol.capturedRequests.contains { $0.url!.absoluteString.contains("synthetic-token") })
    }

    func testPublicDestinationIsRefusedWithoutChangingItsVisibility() async throws {
        StubURLProtocol.handler = { request in
            request.url!.path == "/user" ? (200, [:], self.json(["login": "developer"])) : (200, [:], self.repository(private: false))
        }
        do {
            _ = try await GitHubBackupTransport.connect(token: "synthetic-token", session: session)
            XCTFail("A public repository must not be used for new uploads")
        } catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .publicRepository) }
        XCTAssertTrue(StubURLProtocol.capturedRequests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testAnUnexpectedLoginCannotRedirectTheCredential() async throws {
        StubURLProtocol.handler = { _ in (200, [:], self.json(["login": "../other-host/"])) }
        do { _ = try await GitHubBackupTransport.connect(token: "synthetic-token", session: session); XCTFail() }
        catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .authentication) }
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
    }

    func testVersionListHidesDraftAndMissingCompletionMarker() async throws {
        let validID = UUID(), draftID = UUID(), missingID = UUID()
        func release(_ uuid: UUID, id: Int, draft: Bool, complete: Bool) -> [String: Any] {
            ["id": id, "draft": draft, "tag_name": "exodia-backup-" + uuid.uuidString.lowercased(),
             "body": "exodia.encrypted-backup.v1", "created_at": "2026-10-19T12:00:00Z",
             "assets": complete ? [["id": 100 + id, "name": "complete.exodia-index", "size": 50, "state": "uploaded"]] : []]
        }
        StubURLProtocol.handler = { _ in
            (200, [:], self.json([release(validID, id: 1, draft: false, complete: true),
                                 release(draftID, id: 2, draft: true, complete: true),
                                 release(missingID, id: 3, draft: false, complete: false)]))
        }
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        let versions = try await transport.versions()
        XCTAssertEqual(versions.map(\.id), [validID.uuidString])
    }

    func testUploadReadbackAndCleanDownloadIncludingResumedPublishedVersion() async throws {
        let fixture = RemoteFixture(json: json)
        StubURLProtocol.handler = { request in try fixture.handle(request) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("input.exodiabackup")
        // Crosses the transport part boundary. The archive engine tests the
        // actual ciphertext; this transport treats its input as opaque bytes.
        let input = Data(repeating: 0xA5, count: GitHubBackupTransport.partBytes + 127)
        try input.write(to: original)
        let key = ConfigBackupArchive.makeKey(), id = UUID()
        let summary = ArtifactBackupSummary(id: id, createdAt: Date(), totalBytes: Int64(input.count), fileCount: 2, sections: [.settings, .history])
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        let releaseID = try await transport.upload(file: original, summary: summary, key: key)
        XCTAssertEqual(releaseID, 7)
        XCTAssertFalse(fixture.draft)
        XCTAssertEqual(fixture.uploadNames, ["part-00000.bin", "part-00001.bin", "complete.exodia-index"])
        XCTAssertEqual(fixture.publishCount, 1)
        let secondID = try await transport.upload(file: original, summary: summary, key: key)
        XCTAssertEqual(secondID, releaseID)
        XCTAssertEqual(fixture.uploadNames.count, 3, "Retry must reuse complete assets")
        let restored = root.appendingPathComponent("restored.exodiabackup")
        let version = BackupVersion(id: id.uuidString, createdAt: Date(), size: Int64(input.count), remoteID: releaseID)
        try await transport.download(version: version, to: restored, key: key)
        XCTAssertEqual(try Data(contentsOf: restored), input)
        XCTAssertFalse(StubURLProtocol.capturedRequests.contains { $0.url!.absoluteString.contains("synthetic-token") })
    }

    func testAnInterruptedOrCorruptUploadNeverPublishesTheSnapshot() async throws {
        let fixture = RemoteFixture(json: json); fixture.corruptReadback = true
        StubURLProtocol.handler = { request in try fixture.handle(request) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 3, count: 100).write(to: file)
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        let summary = ArtifactBackupSummary(id: UUID(), createdAt: Date(), totalBytes: 100, fileCount: 1, sections: [.settings])
        do { _ = try await transport.upload(file: file, summary: summary, key: ConfigBackupArchive.makeKey()); XCTFail() }
        catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .incomplete) }
        XCTAssertTrue(fixture.draft); XCTAssertEqual(fixture.publishCount, 0)
        XCTAssertFalse(fixture.uploadNames.contains("complete.exodia-index"))
    }

    func testSignedAssetRedirectStripsTheTokenAndRejectsHTTPAndUnknownHosts() throws {
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com/repos/developer/Exodia-Backup/releases/assets/1")!, statusCode: 302, httpVersion: nil, headerFields: [:])!
        var redirected = URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/signed-object")!)
        redirected.setValue("Bearer synthetic-token", forHTTPHeaderField: "Authorization")
        redirected.setValue("synthetic-cookie", forHTTPHeaderField: "Cookie")
        let safe = try XCTUnwrap(GitHubBackupNetwork.redirectedRequest(redirected, from: response))
        XCTAssertNil(safe.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(safe.value(forHTTPHeaderField: "Cookie"))
        redirected.url = URL(string: "https://attacker.example/object")!
        XCTAssertNil(GitHubBackupNetwork.redirectedRequest(redirected, from: response))
        redirected.url = URL(string: "http://release-assets.githubusercontent.com/object")!
        XCTAssertNil(GitHubBackupNetwork.redirectedRequest(redirected, from: response))
    }

    func testDraftLookupAndResumeSurviveAnInterruptedReadback() async throws {
        let fixture = RemoteFixture(json: json); fixture.failOneReadback = true
        StubURLProtocol.handler = { request in try fixture.handle(request) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 7, count: 1000).write(to: file)
        let summary = ArtifactBackupSummary(id: UUID(), createdAt: Date(), totalBytes: 1000, fileCount: 1, sections: [.settings])
        let key = ConfigBackupArchive.makeKey()
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        do { _ = try await transport.upload(file: file, summary: summary, key: key); XCTFail() } catch { }
        XCTAssertTrue(fixture.draft)
        _ = try await transport.upload(file: file, summary: summary, key: key)
        XCTAssertEqual(fixture.uploadNames, ["part-00000.bin", "complete.exodia-index"])
        XCTAssertEqual(fixture.publishCount, 1)
    }

    func testPartSizingRespectsTheReleaseAssetLimitWithoutAllocatingLargeFiles() throws {
        for bytes: Int64 in [1, 16_777_217, 8 * 1024 * 1024 * 1024, 64 * 1024 * 1024 * 1024 + 2_000_000] {
            let part = try GitHubBackupTransport.partSize(for: bytes)
            XCTAssertLessThanOrEqual(part, GitHubBackupTransport.maximumPartBytes)
            XCTAssertLessThanOrEqual((bytes + Int64(part) - 1) / Int64(part), Int64(GitHubBackupTransport.maximumParts))
        }
        XCTAssertThrowsError(try GitHubBackupTransport.partSize(for: .max))
    }

    private typealias RemoteFixture = BackupGitHubFixture
}
