import XCTest
@testable import Sidekey

@MainActor
final class MeetingBYOKProcessorTests: XCTestCase {
    private var root: URL!
    private var session: URLSession!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        StubURLProtocol.reset()
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }

    func testSonioxSilenceStoresNoSpeechNoteWithoutLLMAndReleasesStagedAudio() async throws {
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [0, 0, 0, 0]).write(to: chunk)
        try Data("{}".utf8).write(to: staging.appendingPathComponent("manifest.json"))
        let fileID = UUID().uuidString, jobID = UUID().uuidString
        StubURLProtocol.handler = { request in
            let path = request.url!.path
            if request.httpMethod == "DELETE" { return (204, [:], Data()) }
            let body: [String: Any]
            if path == "/v1/files" { body = ["id": fileID] }
            else if path == "/v1/transcriptions" { body = ["id": jobID] }
            else if path.hasSuffix("/transcript") { body = ["id": jobID, "text": "", "tokens": []] }
            else { body = ["status": "completed"] }
            return (200, [:], try JSONSerialization.data(withJSONObject: body))
        }

        let setup = Setup(meetings: FeatureRoute(account: .soniox, model: "stt-async-v5"))
        let llm = SpyLLMClient()
        let processor = setup.processor(openRouterClient: llm, sonioxSession: session)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let meetingId = UUID()
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: meetingId,
            chunkURLs: [chunk],
            totalDurationSeconds: 4,
            reason: .user
        )

        let id = try await processor.process(
            event: event,
            startedAt: Date(timeIntervalSince1970: 1_000),
            language: nil,
            meetingsStore: store
        )

        XCTAssertEqual(id, meetingId)
        XCTAssertEqual(llm.completeCalls, 0)
        let meta = try await store.list().first { $0.id == meetingId }
        XCTAssertEqual(meta?.title, "No speech detected")
        XCTAssertEqual(meta?.progressStatus, .ready)
        XCTAssertNil(meta?.failureReason)
        let markdown = try await store.markdown(id: meetingId)
        XCTAssertTrue(markdown?.contains("no speech") == true)
        let transcript = try await store.transcript(id: meetingId)
        XCTAssertEqual(transcript, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        await store.close()
    }

    func testSelfHostedUnparseableBaseURLFailsBeforeAnyTranscription() async throws {
        let setup = Setup()
        let server = setup.routing.addServer(name: "S", baseURL: "http://my host:8000")
        setup.routing.setRoute(FeatureRoute(account: .server(server.id), model: "whisper-1"), for: .meetings)
        let processor = setup.processor(openRouterClient: SpyLLMClient(), sonioxSession: session)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        // No chunks: the adapter is resolved before any audio is read, so the
        // test never opens a socket.
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(),
            chunkURLs: [],
            totalDurationSeconds: 0,
            reason: .user
        )

        do {
            _ = try await processor.process(
                event: event,
                startedAt: Date(timeIntervalSince1970: 1_000),
                language: nil,
                meetingsStore: store
            )
            XCTFail("expected missingSelfHostedBaseURL")
        } catch {
            XCTAssertEqual(error as? MeetingBYOKProcessingError, .missingSelfHostedBaseURL)
        }
        await store.close()
    }

    func test_meeting_uses_the_meetings_route_not_the_drop_route() async throws {
        let setup = Setup(
            meetings: FeatureRoute(account: .deepgram, model: "nova-3"),
            extra: [(.dropFast, FeatureRoute(account: .soniox, model: "stt-rt-v4"))]
        )
        var accounts: [ProviderAccount] = []
        let processor = setup.processor(openRouterClient: SpyLLMClient(), sonioxSession: session) { route in
            accounts.append(route.account)
            throw StopAfterAdapter()
        }
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        do {
            _ = try await processor.process(event: Self.emptyEvent(), startedAt: Date(), language: nil, meetingsStore: store)
            XCTFail("expected the adapter stub to stop the run")
        } catch is StopAfterAdapter {}
        XCTAssertEqual(accounts, [.deepgram])
        await store.close()
    }

    func test_soniox_meeting_sends_the_route_model() async throws {
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [0, 0, 0, 0]).write(to: chunk)
        let fileID = UUID().uuidString, jobID = UUID().uuidString
        StubURLProtocol.handler = { request in
            let path = request.url!.path
            if request.httpMethod == "DELETE" { return (204, [:], Data()) }
            let body: [String: Any]
            if path == "/v1/files" { body = ["id": fileID] }
            else if path == "/v1/transcriptions" { body = ["id": jobID] }
            else if path.hasSuffix("/transcript") { body = ["id": jobID, "text": "", "tokens": []] }
            else { body = ["status": "completed"] }
            return (200, [:], try JSONSerialization.data(withJSONObject: body))
        }
        let setup = Setup(meetings: FeatureRoute(account: .soniox, model: "stt-async-v5"))
        let processor = setup.processor(openRouterClient: SpyLLMClient(), sonioxSession: session)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(), chunkURLs: [chunk], totalDurationSeconds: 4, reason: .user
        )
        _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
        let index = try XCTUnwrap(StubURLProtocol.capturedRequests.firstIndex { $0.url?.path == "/v1/transcriptions" })
        let body = String(decoding: StubURLProtocol.capturedBodies[index], as: UTF8.self)
        XCTAssertTrue(body.contains("\"model\":\"stt-async-v5\""), body)
        await store.close()
    }

    func test_notes_go_to_the_notes_route() async throws {
        let setup = Setup(
            meetings: FeatureRoute(account: .deepgram, model: "nova-3"),
            notes: FeatureRoute(account: .openRouter, model: "anthropic/claude-3.5-haiku")
        )
        let llm = SpyLLMClient()
        let processor = setup.processor(openRouterClient: llm, sonioxSession: session) { _ in
            FixedTranscriptAdapter(text: "Hello team")
        }
        let staging = root.appendingPathComponent("staging").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let chunk = staging.appendingPathComponent("chunk-000.wav")
        try Self.wav(samples: [1, 2, 3, 4]).write(to: chunk)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(), chunkURLs: [chunk], totalDurationSeconds: 4, reason: .user
        )
        _ = try await processor.process(event: event, startedAt: Date(), language: nil, meetingsStore: store)
        XCTAssertEqual(llm.models, ["anthropic/claude-3.5-haiku"])
        XCTAssertEqual(llm.endpoints, [.openRouter(apiKey: "or-key")])
        await store.close()
    }

    func test_meeting_waits_without_a_notes_model() {
        let both = Setup(meetings: FeatureRoute(account: .soniox, model: "stt-async-v5"))
        XCTAssertTrue(both.processor(openRouterClient: SpyLLMClient(), sonioxSession: session).shouldProcessDirectly())
        let noNotes = Setup(meetings: FeatureRoute(account: .soniox, model: "stt-async-v5"), notes: nil)
        XCTAssertFalse(noNotes.processor(openRouterClient: SpyLLMClient(), sonioxSession: session).shouldProcessDirectly())
        let noMeetings = Setup(meetings: nil)
        XCTAssertFalse(noMeetings.processor(openRouterClient: SpyLLMClient(), sonioxSession: session).shouldProcessDirectly())
    }

    func test_not_configured_message_points_to_api_and_models() {
        XCTAssertEqual(
            MeetingsCoordinator.processorNotConfiguredMessage,
            "Choose models for Meetings and Meeting notes in Settings > API & Models to process this meeting."
        )
    }

    func test_missing_meetings_key_maps_to_the_transcription_key_error() async throws {
        let setup = Setup(meetings: FeatureRoute(account: .deepgram, model: "nova-3"), saveMeetingsKey: false)
        let processor = setup.processor(openRouterClient: SpyLLMClient(), sonioxSession: session)
        let store = try MeetingsStore(rootDirectory: root.appendingPathComponent("store"))
        do {
            _ = try await processor.process(event: Self.emptyEvent(), startedAt: Date(), language: nil, meetingsStore: store)
            XCTFail("expected missingTranscriptionKey")
        } catch {
            XCTAssertEqual(error as? MeetingBYOKProcessingError, .missingTranscriptionKey)
        }
        await store.close()
    }

    private static func emptyEvent() -> MeetingRecorder.FinalizedEvent {
        MeetingRecorder.FinalizedEvent(meetingId: UUID(), chunkURLs: [], totalDurationSeconds: 0, reason: .user)
    }

    /// In-memory routing and keys: a Meetings route (with its provider's key),
    /// a Meeting notes route on OpenRouter (key `or-key`), and any extra routes.
    @MainActor private struct Setup {
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        let vocab: VocabularyCache

        init(
            meetings: FeatureRoute? = nil,
            notes: FeatureRoute? = FeatureRoute(account: .openRouter, model: "openrouter/auto"),
            extra: [(AIFeature, FeatureRoute)] = [],
            saveMeetingsKey: Bool = true
        ) {
            let defaults = UserDefaults(suiteName: "meeting.byok.\(UUID().uuidString)")!
            routing = AIRoutingStore(defaults: defaults)
            let box = InMemoryTokenStore.Box()
            keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
            vocab = VocabularyCache(defaults: defaults)
            routing.setRoute(meetings, for: .meetings)
            routing.setRoute(notes, for: .meetingNotes)
            for (feature, route) in extra { routing.setRoute(route, for: feature) }
            try? keys.save("or-key", account: OpenRouterLLMKeyStore.account)
            if saveMeetingsKey, let account = meetings?.account.keychainAccount(in: routing) {
                try? keys.save("meetings-key", account: account)
            }
            for (_, route) in extra {
                if let account = route.account.keychainAccount(in: routing) {
                    try? keys.save("extra-key", account: account)
                }
            }
        }

        @MainActor
        func processor(
            openRouterClient: any OpenRouterLLMClienting,
            sonioxSession: URLSession,
            makeAdapter: @escaping (ResolvedRoute) throws -> BYOKTranscriptionAdapter = RealtimeAdapterFactory.make
        ) -> MeetingBYOKProcessor {
            MeetingBYOKProcessor(
                routing: routing,
                keys: keys,
                vocab: vocab,
                notesRoute: DirectLLMRouteResolver(feature: .meetingNotes, routing: routing, keys: keys),
                openRouterClient: openRouterClient,
                sonioxSession: sonioxSession,
                makeAdapter: makeAdapter
            )
        }
    }

    private static func wav(samples: [UInt8]) -> Data {
        var data = Data("RIFF".utf8)
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(samples.count + 36)); data.append(Data("WAVEfmt ".utf8)); append(16)
        data.append(contentsOf: [1, 0, 1, 0]); append(16000); append(32000)
        data.append(contentsOf: [2, 0, 16, 0]); data.append(Data("data".utf8)); append(UInt32(samples.count))
        data.append(contentsOf: samples)
        return data
    }
}

private struct StopAfterAdapter: Error {}

private final class SpyLLMClient: OpenRouterLLMClienting {
    private(set) var completeCalls = 0
    private(set) var models: [String] = []
    private(set) var endpoints: [OpenAICompatibleLLMEndpoint] = []

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] {
        []
    }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        completeCalls += 1
        models.append(model)
        endpoints.append(endpoint)
        return "<!-- protocol:v1 -->\n# Unexpected note"
    }
}

private struct FixedTranscriptAdapter: BYOKTranscriptionAdapter {
    let text: String

    func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession {
        FixedTranscriptSession(text: text)
    }
}

private final class FixedTranscriptSession: BYOKUpstreamSession {
    let events: AsyncStream<BYOKStreamEvent>
    private let continuation: AsyncStream<BYOKStreamEvent>.Continuation
    private let text: String

    init(text: String) {
        self.text = text
        (events, continuation) = AsyncStream.makeStream(of: BYOKStreamEvent.self)
    }

    func sendAudio(_ pcm: Data) async {}
    func endInput() async { continuation.yield(.done(text)); continuation.finish() }
    func close() async { continuation.finish() }
}
