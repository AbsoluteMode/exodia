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

        let defaults = UserDefaults(suiteName: "meeting.byok.\(UUID().uuidString)")!
        let prefs = SelfKeyPreferences(defaults: defaults)
        prefs.transcriptionLevel = .yourKey
        prefs.selectedProvider = .soniox
        prefs.llmLevel = .yourKey
        let keyStore = BYOKKeyStore.inMemory()
        try keyStore.save(key: "soniox-key", for: .soniox)
        let llm = SpyLLMClient()
        let processor = MeetingBYOKProcessor(
            prefs: prefs,
            keyStore: keyStore,
            vocab: VocabularyCache(defaults: defaults),
            llmRouteResolver: DirectLLMRouteResolver(
                prefs: prefs,
                llmKeyStore: StaticLLMKeyStore(key: "or-key"),
                customLLMKeyStore: StaticLLMKeyStore(key: nil)
            ),
            openRouterClient: llm,
            sonioxSession: session
        )
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
        let defaults = UserDefaults(suiteName: "meeting.byok.\(UUID().uuidString)")!
        let prefs = SelfKeyPreferences(defaults: defaults)
        prefs.transcriptionLevel = .yourKey
        prefs.selectedProvider = .selfHosted
        prefs.selfHostedBaseURL = "http://my host:8000"
        prefs.llmLevel = .yourKey
        let keyStore = BYOKKeyStore.inMemory()
        try keyStore.save(key: "self-hosted-key", for: .selfHosted)
        let processor = MeetingBYOKProcessor(
            prefs: prefs,
            keyStore: keyStore,
            vocab: VocabularyCache(defaults: defaults),
            llmRouteResolver: DirectLLMRouteResolver(
                prefs: prefs,
                llmKeyStore: StaticLLMKeyStore(key: "or-key"),
                customLLMKeyStore: StaticLLMKeyStore(key: nil)
            ),
            openRouterClient: SpyLLMClient(),
            sonioxSession: session
        )
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

private final class SpyLLMClient: OpenRouterLLMClienting {
    private(set) var completeCalls = 0

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] {
        []
    }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        completeCalls += 1
        return "<!-- protocol:v1 -->\n# Unexpected note"
    }
}

private final class StaticLLMKeyStore: OpenRouterLLMKeyStoring {
    var key: String?

    init(key: String?) {
        self.key = key
    }

    func save(key: String) throws {
        self.key = key
    }

    func read() throws -> String? {
        key
    }

    func delete() throws {
        key = nil
    }
}
