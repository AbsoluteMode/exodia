import XCTest
@testable import Sidekey

/// A resolved route becomes the real-time adapter of the route's own provider.
/// Nothing here opens a socket: an adapter only builds its transport once it
/// is opened, and these tests never open one.
final class RealtimeAdapterFactoryTests: XCTestCase {

    private func route(
        _ account: ProviderAccount,
        feature: AIFeature = .dropFast,
        apiKey: String? = "sk-test",
        server: ServerEndpoint? = nil
    ) -> ResolvedRoute {
        ResolvedRoute(feature: feature, account: account, model: "some-model", apiKey: apiKey, server: server)
    }

    private func makeServer(baseURL: String) -> ServerEndpoint {
        ServerEndpoint(id: UUID(), name: "Home GPU", baseURL: baseURL, keyAccount: "byok.selfHosted.api_key")
    }

    func test_builds_the_adapter_of_the_route_provider() throws {
        XCTAssertTrue(try RealtimeAdapterFactory.make(route(.soniox)) is SonioxBYOKAdapter)
        XCTAssertTrue(try RealtimeAdapterFactory.make(route(.deepgram)) is DeepgramBYOKAdapter)
        XCTAssertTrue(try RealtimeAdapterFactory.make(route(.elevenLabs)) is ElevenLabsBYOKAdapter)

        // A server's key is optional: no key still builds the adapter.
        let server = makeServer(baseURL: "https://gpu.local:8000")
        XCTAssertTrue(try RealtimeAdapterFactory.make(route(.server(server.id), apiKey: nil, server: server)) is OpenAIRealtimeAdapter)
        XCTAssertTrue(try RealtimeAdapterFactory.make(route(.server(server.id), apiKey: "sk-server", server: server)) is OpenAIRealtimeAdapter)
    }

    func test_server_without_host_fails_before_any_socket() {
        for baseURL in ["", "http://my host:8000"] {
            let server = makeServer(baseURL: baseURL)
            let broken = route(.server(server.id), feature: .meetings, apiKey: nil, server: server)

            XCTAssertThrowsError(try RealtimeAdapterFactory.make(broken), "base URL \"\(baseURL)\"") { error in
                XCTAssertEqual(error as? FeatureRouteError, .invalidBaseURL(.meetings))
            }
        }
    }

    func test_server_route_without_its_endpoint_fails_instead_of_guessing_a_host() {
        let orphan = route(.server(UUID()), feature: .agentVoice, apiKey: "sk-server", server: nil)

        XCTAssertThrowsError(try RealtimeAdapterFactory.make(orphan)) { error in
            XCTAssertEqual(error as? FeatureRouteError, .invalidBaseURL(.agentVoice))
        }
    }

    func test_openrouter_has_no_realtime_adapter() {
        XCTAssertThrowsError(try RealtimeAdapterFactory.make(route(.openRouter, feature: .voiceSearch))) { error in
            XCTAssertEqual(error as? FeatureRouteError, .notSet(.voiceSearch))
        }
    }

    func test_hosted_provider_without_a_key_is_missing_key() {
        for account in [ProviderAccount.soniox, .deepgram, .elevenLabs] {
            for key in [nil, ""] as [String?] {
                XCTAssertThrowsError(
                    try RealtimeAdapterFactory.make(route(account, feature: .agentVoice, apiKey: key)),
                    "\(account) with key \(String(describing: key))"
                ) { error in
                    XCTAssertEqual(error as? FeatureRouteError, .missingKey(.agentVoice))
                }
            }
        }
    }
}
