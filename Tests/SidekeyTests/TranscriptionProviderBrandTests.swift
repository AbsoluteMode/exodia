import XCTest
@testable import Sidekey

final class TranscriptionProviderBrandTests: XCTestCase {
    // MARK: agent(_:)

    func testAgentCodexBrand() {
        let brand = TranscriptionProviderBrand.agent(.codex)
        XCTAssertEqual(brand.assetName, "codex")
        XCTAssertEqual(brand.label, "Codex")
        XCTAssertNil(brand.systemName)
    }

    func testAgentClaudeBrand() {
        let brand = TranscriptionProviderBrand.agent(.claude)
        XCTAssertEqual(brand.assetName, "claude-code")
        XCTAssertEqual(brand.label, "Claude Code")
        XCTAssertNil(brand.systemName)
    }

    func testAgentCoversEveryCLIProvider() {
        // Every provider has exactly one renderable icon and a user-facing name.
        // OpenCode uses the native terminal symbol; existing brands use assets.
        for provider in CLIProviderID.allCases {
            let brand = TranscriptionProviderBrand.agent(provider)
            XCTAssertNotEqual(brand.assetName == nil, brand.systemName == nil, "agent(\(provider)) must have exactly one icon")
            XCTAssertFalse(brand.label.isEmpty, "agent(\(provider)) has empty label")
        }
    }

    // MARK: google

    func testGoogleBrand() {
        let brand = TranscriptionProviderBrand.google
        XCTAssertEqual(brand.assetName, "google")
        XCTAssertEqual(brand.label, "Google")
        XCTAssertNil(brand.systemName)
    }

    // MARK: OpenRouter

    func testOpenRouterBrand() {
        let brand = TranscriptionProviderBrand.openRouter
        XCTAssertEqual(brand.assetName, "openrouter")
        XCTAssertEqual(brand.label, "OpenRouter")
        XCTAssertNil(brand.systemName)
    }

    func testCustomLLMBrand() {
        let brand = TranscriptionProviderBrand.customLLM
        XCTAssertNil(brand.assetName)
        XCTAssertEqual(brand.label, "Custom LLM")
        XCTAssertEqual(brand.systemName, "server.rack")
    }

    // MARK: routes

    @MainActor
    private func makeRouting() -> AIRoutingStore {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AIRoutingStore(defaults: defaults)
    }

    @MainActor
    func test_brand_for_built_in_accounts_keeps_the_old_assets() {
        let routing = makeRouting()
        XCTAssertEqual(TranscriptionProviderBrand.brand(for: .soniox, in: routing),
                       TranscriptionProviderBrand(assetName: "soniox", label: "Soniox"))
        XCTAssertEqual(TranscriptionProviderBrand.brand(for: .deepgram, in: routing),
                       TranscriptionProviderBrand(assetName: "deepgram", label: "Deepgram"))
        XCTAssertEqual(TranscriptionProviderBrand.brand(for: .elevenLabs, in: routing),
                       TranscriptionProviderBrand(assetName: "elevenlabs", label: "ElevenLabs"))
        XCTAssertEqual(TranscriptionProviderBrand.brand(for: .openRouter, in: routing), .openRouter)
    }

    @MainActor
    func test_brand_for_a_server_shows_its_name() {
        let routing = makeRouting()
        let server = routing.addServer(name: "llm.local", baseURL: "http://llm.local/v1")
        let brand = TranscriptionProviderBrand.brand(for: .server(server.id), in: routing)
        XCTAssertEqual(brand.systemName, "server.rack")
        XCTAssertNil(brand.assetName)
        XCTAssertEqual(brand.label, "llm.local")
    }

    @MainActor
    func test_drop_brand_follows_the_latched_take() {
        let routing = makeRouting()
        let take = DropTake()
        XCTAssertNil(TranscriptionProviderBrand.currentDrop(take: take, routing: routing))

        take.begin(mode: .fast, route: FeatureRoute(account: .elevenLabs, model: "scribe_v2_realtime"))
        XCTAssertEqual(TranscriptionProviderBrand.currentDrop(take: take, routing: routing)?.label, "ElevenLabs")

        // The route held by the take wins over the store's current route.
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v4"), for: .dropFast)
        XCTAssertEqual(TranscriptionProviderBrand.currentDrop(take: take, routing: routing)?.label, "ElevenLabs")

        take.begin(mode: .smart, route: nil)
        XCTAssertNil(TranscriptionProviderBrand.currentDrop(take: take, routing: routing))
    }

    @MainActor
    func test_cleanup_brand_follows_the_cleanup_route() {
        let routing = makeRouting()
        XCTAssertNil(TranscriptionProviderBrand.currentDropCleanup(routing: routing))

        routing.setRoute(FeatureRoute(account: .openRouter, model: "anthropic/claude-haiku-4.5"), for: .dropSmartCleanup)
        XCTAssertEqual(TranscriptionProviderBrand.currentDropCleanup(routing: routing), .openRouter)

        let server = routing.addServer(name: "llm.local", baseURL: "http://llm.local/v1")
        routing.setRoute(FeatureRoute(account: .server(server.id), model: "qwen"), for: .dropSmartCleanup)
        let brand = TranscriptionProviderBrand.currentDropCleanup(routing: routing)
        XCTAssertEqual(brand?.systemName, "server.rack")
        XCTAssertEqual(brand?.label, "llm.local")
    }

    // MARK: assets resolve to bundled files

    func testRecordingSourceBrandAssetsAreBundled() throws {
        let iconDir = try projectRoot().appendingPathComponent("Resources/UsefulLinkIcons")
        let brands: [TranscriptionProviderBrand] = [
            .agent(.codex),
            .agent(.claude),
            .google,
            .openRouter,
        ]
        for brand in brands {
            let assetName = try XCTUnwrap(brand.assetName, "brand \(brand.label) missing assetName")
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: iconDir.appendingPathComponent("\(assetName).pdf").path
                ),
                "Missing \(assetName).pdf for brand \(brand.label)"
            )
        }
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "TranscriptionProviderBrandTests", code: 1)
    }
}
