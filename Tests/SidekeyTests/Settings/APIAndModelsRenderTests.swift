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
                    try render(
                        APIAndModelsView(viewModel: vm, focusedFeature: .constant(nil),
                                         initiallyExpandedGroup: expanded),
                        size: NSSize(width: width, height: 980), dark: dark,
                        to: directory.appendingPathComponent("models-\(state)-\(dark ? "dark" : "light")-\(Int(width)).png")
                    )
                }
            }
        }
        // What the Agent row's provider menu lists (a menu itself is not drawn offscreen).
        try render(
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

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool = true, to url: URL) throws {
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
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
