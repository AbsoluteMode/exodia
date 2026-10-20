import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Offscreen pictures of API & Models for review, written only when
/// `EXODIA_APIMODELS_RENDER_DIR` is set. Every network path is a stub.
@MainActor
final class APIAndModelsRenderTests: XCTestCase {
    private struct NoNetwork: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching {
        let list: [OpenRouterEndpoint]
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
            throw CatalogFetchError.offline
        }
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus { .valid }
        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
        func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { list }
    }

    func test_render_api_and_models() async throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_APIMODELS_RENDER_DIR"] else {
            throw XCTSkip("set EXODIA_APIMODELS_RENDER_DIR to write the pictures")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        try Data("{}".utf8).write(to: file)
        let list = OpenRouterEndpointsClient.sorted([
            OpenRouterEndpoint(tag: "anthropic", providerName: "Anthropic", quantization: nil, latencyMs: 1_240, tokensPerSecond: 58, isUp: true),
            OpenRouterEndpoint(tag: "amazon-bedrock", providerName: "Amazon Bedrock", quantization: nil, latencyMs: 1_610, tokensPerSecond: 64, isUp: true),
            OpenRouterEndpoint(tag: "google-vertex/global", providerName: "Google", quantization: nil, latencyMs: 1_980, tokensPerSecond: 51, isUp: true),
        ])
        let stub = NoNetwork(list: list)
        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        for account in [ProviderAccount.soniox, .deepgram, .elevenLabs, .openRouter] {
            try keys.save("key", account: XCTUnwrap(account.keychainAccount(in: routing)))
        }
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropSmart)
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-async-v5"), for: .meetings)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .dropSmartCleanup)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .meetingNotes)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5", provider: "anthropic"), for: .agent)
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .subtitlesAudio)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .subtitlesTranslation)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "qwen/qwen3.8-27b"), for: .translation)
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .agentVoice)

        let vm = APIAndModelsViewModel(
            routing: routing, keys: keys,
            catalogs: ModelCatalogStore(fileURL: file, fetcher: stub), checks: ModelCheckStore(defaults: defaults),
            keyStatuses: KeyStatusStore(defaults: defaults), keyChecker: stub, probe: stub, endpoints: stub,
            inputLanguage: { "ru" }
        )
        for feature in [AIFeature.agent, .meetingNotes, .dropSmartCleanup, .translation, .subtitlesTranslation] { await vm.loadProviders(for: feature) }

        for dark in [false, true] {
            for width in [600.0, 900.0] {
                for expanded in [nil, "Drop Smart", "Subtitles"] as [String?] {
                    let state = expanded == "Subtitles" ? "subtitles-expanded" : (expanded == nil ? "collapsed" : "expanded")
                    try await render(
                        APIAndModelsView(viewModel: vm, focusedFeature: .constant(nil),
                                         initiallyExpandedGroup: expanded),
                        size: NSSize(width: width, height: 980), dark: dark,
                        to: directory.appendingPathComponent("models-\(state)-\(dark ? "dark" : "light")-\(Int(width)).png")
                    )
                }
            }
        }
        // Costs use a temporary journal and synthetic provider metadata only.
        let usageURL = directory.appendingPathComponent("fixture-usage.sqlite")
        try? FileManager.default.removeItem(at: usageURL)
        let usageStore = AIUsageStore(url: usageURL)
        let fixtureNow = Date()
        let usageModel = AIUsageCostsViewModel(store: usageStore)
        let usageEvents: [AIUsageEvent] = [
            .speech(.init(feature: .dropSmart, account: .soniox, model: "stt-rt-v5"), seconds: 300, at: fixtureNow),
            .init(createdAt: fixtureNow, context: .init(feature: .dropSmartCleanup, account: .openRouter, model: "google/gemini-3.8-flash"), currency: .usd, amount: 0.02, basis: .reported),
            .init(createdAt: fixtureNow, context: .init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2_realtime"), currency: .elevenLabsCredits, amount: 1234, basis: .reported),
            .init(createdAt: fixtureNow, context: .init(feature: .agent, account: .anthropic, model: "claude-opus-5-5"), currency: .usd, amount: 0.48, basis: .estimated),
            .init(createdAt: fixtureNow, context: .init(feature: .agent, account: .anthropic, model: "claude-sonnet-5-5"), currency: .usd, amount: nil, basis: .unavailable)
        ]
        for event in usageEvents { try await usageStore.insert(event) }
        let interval = AIUsagePeriod.month.interval(now: fixtureNow, start: fixtureNow, end: fixtureNow)!
        await usageModel.load(interval)
        for dark in [false, true] {
            for width in [600.0, 900.0] {
                for section in APIAndModelsSection.allCases {
                    try await render(APIAndModelsView(viewModel: vm, focusedFeature: .constant(nil),
                        initialSection: section, usageModel: usageModel), size: NSSize(width: width, height: 700), dark: dark,
                        to: directory.appendingPathComponent("sections-\(section)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
            }
            let manyModels = (0..<20).map { index in
                AIUsageEvent(createdAt: fixtureNow, context: .init(feature: .agent, account: .openRouter,
                    model: "provider/very-long-model-name-for-history-\(index)-with-an-extended-version-identifier"),
                    currency: .usd, amount: Double(index) / 100, basis: .reported)
            }
            try await render(AIUsageModelsPopover(row: .init(title: "Agent", events: manyModels)),
                size: NSSize(width: 390, height: 390), dark: dark,
                to: directory.appendingPathComponent("cost-models-many-\(dark ? "dark" : "light").png"))
        }
        // What the Agent row's provider menu lists (a menu itself is not drawn offscreen).
        try await render(
            VStack(alignment: .leading, spacing: 6) {
                Text("   Auto")
                Divider()
                ForEach(list, id: \.tag) { endpoint in
                    Text("\(endpoint.tag == "anthropic" ? "✓ " : "   ")\(endpoint.title)   \(endpoint.speedText)")
                }
            }
            .font(.system(size: 13))
            .padding(12)
            .frame(width: 360, alignment: .leading),
            size: NSSize(width: 360, height: 150),
            to: directory.appendingPathComponent("provider-menu-items.png")
        )
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool = true, to url: URL) async throws {
        let host = NSHostingView(rootView: view.background(MacSettingsTheme.bgContent)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
