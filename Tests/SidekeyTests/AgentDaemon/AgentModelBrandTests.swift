import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class AgentModelBrandTests: XCTestCase {
    func testVoiceMarkFollowsModelAuthorInsteadOfHostingProvider() {
        let route = FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5", provider: "amazon-bedrock")
        let brand = TranscriptionProviderBrand.agent(.native, route: route)
        XCTAssertEqual(brand.modelBrand, .anthropic)
        XCTAssertEqual(brand.assetName, "model-anthropic")
        XCTAssertNil(brand.systemName)
        XCTAssertEqual(AgentModelBrand.resolve(.init(account: .openAI, model: "exact-user-model")), .openai)
        XCTAssertEqual(AgentModelBrand.resolve(.init(account: .anthropic, model: "exact-user-model")), .anthropic)
        XCTAssertEqual(AgentModelBrand.resolve(.init(account: .openRouter, model: "openrouter/google/gemini-3.8-flash")), .google)
        XCTAssertNil(AgentModelBrand.resolve(.init(account: .openRouter, model: "some-team/openai-compatible")))
        XCTAssertEqual(TranscriptionProviderBrand.agent(.native, route: .init(account: .openRouter, model: "openrouter/auto")), .openRouter)
    }

    private func fixture() throws -> (URLSession, URL, Data) {
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        addTeardownBlock { session.invalidateAndCancel(); StubURLProtocol.reset(); try? FileManager.default.removeItem(at: dir) }
        return (session, dir, png)
    }

    func testCacheSurvivesRelaunchAndRevalidatesWeeklyWithoutKeysOrModelRequests() async throws {
        let (session, dir, png) = try fixture()
        var date = Date(timeIntervalSince1970: 100_000)
        StubURLProtocol.handler = { _ in (200, ["ETag": "icon-v1"], png) }
        let first = AgentModelIconStore(session: session, directory: dir, now: { date })
        let initial = await first.image(for: .openai)
        XCTAssertNotNil(initial)
        let second = AgentModelIconStore(session: session, directory: dir, now: { date })
        let cached = await second.image(for: .openai)
        XCTAssertNotNil(cached)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        date = date.addingTimeInterval(AgentModelIconStore.refreshInterval + 1)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "icon-v1")
            return (304, [:], Data())
        }
        let revalidated = await second.image(for: .openai)
        XCTAssertNotNil(revalidated)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 2)
        for request in StubURLProtocol.capturedRequests {
            XCTAssertEqual(request.url, AgentModelBrand.openai.iconURL)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.httpBody)
        }
    }

    func testFailedRefreshKeepsUsableImageAndBacksOff() async throws {
        let (session, dir, png) = try fixture()
        var date = Date(timeIntervalSince1970: 100_000)
        StubURLProtocol.handler = { _ in (200, [:], png) }
        let store = AgentModelIconStore(session: session, directory: dir, now: { date })
        let first = await store.image(for: .google)
        XCTAssertNotNil(first)
        date = date.addingTimeInterval(AgentModelIconStore.refreshInterval + 1)
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let stale = await store.image(for: .google)
        let repeated = await store.image(for: .google)
        XCTAssertNotNil(stale)
        XCTAssertNotNil(repeated)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 2)
    }

    func testConcurrentViewsShareDownloadAndInvalidArtworkDoesNotReplaceFallback() async throws {
        let (session, dir, _) = try fixture()
        StubURLProtocol.handler = { _ in (200, [:], Data("not an image".utf8)) }
        let store = AgentModelIconStore(session: session, directory: dir)
        async let a = store.image(for: .anthropic)
        async let b = store.image(for: .anthropic)
        let results = await [a, b]
        XCTAssertTrue(results.allSatisfy { $0 == nil })
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("anthropic.json").path))
    }

    func testAnthropicArtworkKeepsTheMonogramRatherThanAnOpaqueTile() async throws {
        let (session, dir, _) = try fixture()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try Data(contentsOf: root.appendingPathComponent("Resources/UsefulLinkIcons/model-anthropic.svg"))
        StubURLProtocol.handler = { _ in (200, [:], source) }
        let store = AgentModelIconStore(session: session, directory: dir)
        let loaded = await store.image(for: .anthropic)
        let image = try XCTUnwrap(loaded)
        XCTAssertEqual(image.size.width / image.size.height, 310.0 / 250.0, accuracy: 0.001)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0))
        XCTAssertLessThan(corner.alphaComponent, 0.01)
    }
}
