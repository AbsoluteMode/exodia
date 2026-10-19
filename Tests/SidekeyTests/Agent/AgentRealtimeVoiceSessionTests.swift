import XCTest
@testable import Sidekey

@MainActor
final class AgentRealtimeVoiceSessionTests: XCTestCase {
    func testProductionSessionsConformToProtocol() {
        // Compile-time proof the production session satisfies the protocol
        // the controller depends on.
        let _: any AgentRealtimeVoiceSessioning.Type = DirectProviderStreamingSession.self
    }
}
