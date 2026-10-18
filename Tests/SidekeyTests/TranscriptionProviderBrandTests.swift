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

    func testProviderBrandsDefaultToMonochrome() {
        // Every provider mark stays template/white in the island.
        XCTAssertFalse(TranscriptionProviderBrand.agent(.codex).isFullColor)
        XCTAssertFalse(TranscriptionProviderBrand.agent(.claude).isFullColor)
        XCTAssertFalse(TranscriptionProviderBrand.google.isFullColor)
        XCTAssertFalse(TranscriptionProviderBrand.openRouter.isFullColor)
        XCTAssertFalse(TranscriptionProviderBrand.customLLM.isFullColor)
        XCTAssertFalse(TranscriptionProviderBrand.byok(.soniox).isFullColor)
    }

    @MainActor
    func testCurrentDropBrandIsNilWithoutChosenProvider() {
        // A retired on-device choice reads as "no provider chosen" on any
        // hardware: no audio goes to a provider, so there is no brand to show.
        withStoredLevel("local", forKey: "sidekey.models.transcriptionLevel") {
            XCTAssertNil(TranscriptionProviderBrand.currentDrop())
        }
    }

    @MainActor
    func testCurrentDropBrandReturnsSelectedProviderForYourKey() {
        let prefs = SelfKeyPreferences.shared
        let originalLevel = prefs.transcriptionLevel
        let originalProvider = prefs.selectedProvider
        defer {
            prefs.transcriptionLevel = originalLevel
            prefs.selectedProvider = originalProvider
        }

        prefs.transcriptionLevel = .yourKey
        prefs.selectedProvider = .deepgram

        XCTAssertEqual(TranscriptionProviderBrand.currentDrop(), .byok(.deepgram))
    }

    @MainActor
    func testCurrentDropCleanupBrandFollowsLLMRoute() {
        let prefs = SelfKeyPreferences.shared
        let originalLLMLevel = prefs.llmLevel
        defer { prefs.llmLevel = originalLLMLevel }

        prefs.llmLevel = .yourKey
        XCTAssertEqual(TranscriptionProviderBrand.currentDropCleanup(), .openRouter)

        prefs.llmLevel = .custom
        XCTAssertEqual(TranscriptionProviderBrand.currentDropCleanup(), .customLLM)

        // No route chosen (a retired on-device choice): nothing to surface.
        withStoredLevel("local", forKey: "sidekey.models.llmLevel") {
            XCTAssertNil(TranscriptionProviderBrand.currentDropCleanup())
        }
    }

    /// Stores a raw level in the defaults `SelfKeyPreferences.shared` reads,
    /// runs `body`, then restores whatever was stored before.
    @MainActor
    private func withStoredLevel(_ rawValue: String, forKey key: String, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set(rawValue, forKey: key)
        body()
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
