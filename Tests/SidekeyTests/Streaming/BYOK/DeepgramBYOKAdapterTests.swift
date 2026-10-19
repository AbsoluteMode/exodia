import XCTest
@testable import Sidekey

@MainActor
final class DeepgramBYOKAdapterTests: XCTestCase {
    func testURLCarriesModelEncodingLanguageAndKeyterms() throws {
        let url = try DeepgramRealtimeURL.make(model: "nova-3", language: "ru", terms: ["Whytap", "Sidekey"])
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = comps.queryItems ?? []
        func vals(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap { $0.value } }
        XCTAssertEqual(comps.scheme, "wss")
        XCTAssertEqual(comps.host, "api.deepgram.com")
        XCTAssertEqual(comps.path, "/v1/listen")
        XCTAssertEqual(vals("model"), ["nova-3"])
        XCTAssertEqual(vals("encoding"), ["linear16"])
        XCTAssertEqual(vals("sample_rate"), ["16000"])
        XCTAssertEqual(vals("channels"), ["1"])
        XCTAssertEqual(vals("interim_results"), ["true"])
        XCTAssertEqual(vals("language"), ["ru"])
        XCTAssertEqual(vals("keyterm"), ["Whytap", "Sidekey"])  // repeated, one per term
    }

    // Omitting language silently enables English, not Auto, at Deepgram.
    func testURLAutoUsesMultilingualWithoutChangingModelOrEnablingLanguageDetection() throws {
        for language in [nil, ""] as [String?] {
            let url = try DeepgramRealtimeURL.make(model: "nova-3", language: language, terms: [])
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertEqual(items.filter { $0.name == "language" }.map(\.value), ["multi"])
            XCTAssertEqual(items.first { $0.name == "model" }?.value, "nova-3")
            XCTAssertFalse(items.contains { $0.name == "detect_language" || $0.name == "keyterm" })
        }
    }

    func testUnsupportedLanguageFailsBeforeCreatingTransport() async {
        var transportWasCreated = false
        let adapter = DeepgramBYOKAdapter(model: "nova-3") { _, _ in
            transportWasCreated = true
            return StubWebSocketTransport()
        }
        do {
            _ = try await adapter.open(language: "cy", terms: [])
            XCTFail("Welsh is not supported by Nova-3")
        } catch {
            XCTAssertEqual(error as? DeepgramLanguageConfigurationError, .unsupportedLanguage)
        }
        XCTAssertFalse(transportWasCreated)
    }

    func testUnknownModelAutoFailsBeforeCreatingTransport() async {
        var transportWasCreated = false
        let adapter = DeepgramBYOKAdapter(model: "user-custom-model") { _, _ in
            transportWasCreated = true
            return StubWebSocketTransport()
        }
        do {
            _ = try await adapter.open(language: nil, terms: [])
            XCTFail("Unknown models must not quietly fall back to English")
        } catch {
            XCTAssertEqual(error as? DeepgramLanguageConfigurationError, .automaticLanguageUnavailable)
        }
        XCTAssertFalse(transportWasCreated)
    }

    func testSendAudioIsRawBinaryAndEndInputClosesStream() async throws {
        let stub = StubWebSocketTransport()
        let adapter = DeepgramBYOKAdapter(model: "nova-3") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        await session.sendAudio(Data([0x01, 0x02, 0x03, 0x04]))
        await session.endInput()
        XCTAssertEqual(stub.sent.first, .data(Data([0x01, 0x02, 0x03, 0x04])))  // no base64, no resample
        let texts = stub.sent.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
        XCTAssertTrue(texts.contains { $0.contains("CloseStream") })
        await session.close()
    }

    func testEventsNormalizeInterimFinalThenDoneOnClose() async throws {
        let stub = StubWebSocketTransport()
        let adapter = DeepgramBYOKAdapter(model: "nova-3") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        stub.deliverText(#"{"channel":{"alternatives":[{"transcript":"hel"}]},"is_final":false}"#)
        stub.deliverText(#"{"channel":{"alternatives":[{"transcript":"hello"}]},"is_final":true}"#)
        // Simulate the server closing the socket. Use `deliver(.failure)` (queued
        // in order) rather than `cancel()` (only drains already-waiting receives),
        // so the close is consumed deterministically after the two frames above —
        // no race with the receive loop registering its continuation.
        stub.deliver(.failure(StreamingSessionError.transportCancelled))
        var got: [BYOKStreamEvent] = []
        for await ev in session.events { got.append(ev); if case .done = ev { break } }
        XCTAssertTrue(got.contains(.partial("hel")))
        XCTAssertTrue(got.contains(.final("hello")))
        XCTAssertEqual(got.last, .done("hello"))
    }

    func testConnectFailureWithNoFramesEmitsError() async throws {
        let stub = StubWebSocketTransport()
        let adapter = DeepgramBYOKAdapter(model: "nova-3") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        // Immediate close before any frame → handshake/auth failure. Queued
        // failure (not `cancel()`) so it is delivered race-free to the loop.
        stub.deliver(.failure(StreamingSessionError.transportCancelled))
        var got: [BYOKStreamEvent] = []
        for await ev in session.events { got.append(ev); break }
        XCTAssertEqual(got.first, .error("transport"))
    }
}
