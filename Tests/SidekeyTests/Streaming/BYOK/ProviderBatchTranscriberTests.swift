import XCTest
@testable import Sidekey

/// The batch route is the provider and key the user chose in Settings ->
/// Models, exactly what the realtime path uses, or nothing.
/// WHY: .project-docs/decisions/2026-10-18-provider-batch-transcription.md
@MainActor
final class ProviderBatchRouteTests: XCTestCase {
    private var defaults: UserDefaults!
    private var keys: BYOKKeyStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "provider.batch.\(UUID().uuidString)")!
        keys = BYOKKeyStore.inMemory()
    }

    private func prefs(_ provider: BYOKProvider) -> SelfKeyPreferences {
        let prefs = SelfKeyPreferences(defaults: defaults, isAppleSilicon: true)
        prefs.transcriptionLevel = .yourKey
        prefs.selectedProvider = provider
        return prefs
    }

    // Breaks if a former on-device user (no level stored on Apple Silicon)
    // starts sending audio to a provider just because a key is stored.
    func test_noChosenProvider_isNotConfigured_evenWithAStoredKey() throws {
        try keys.save(key: "sx-key", for: .soniox)
        let prefs = SelfKeyPreferences(defaults: defaults, isAppleSilicon: true)
        XCTAssertNil(ProviderBatchRoute.current(prefs: prefs, keyStore: keys))
    }

    // Breaks if batch borrows another provider's key when the selected one
    // has none, moving the audio somewhere the user did not choose.
    func test_selectedProviderWithoutKey_neverUsesAnotherProvidersKey() throws {
        try keys.save(key: "sx-key", for: .soniox)
        try keys.save(key: "el-key", for: .elevenLabs)
        XCTAssertNil(ProviderBatchRoute.current(prefs: prefs(.deepgram), keyStore: keys))
    }

    func test_soniox_usesTheStoredKey() throws {
        try keys.save(key: "sx-key", for: .soniox)
        XCTAssertEqual(ProviderBatchRoute.current(prefs: prefs(.soniox), keyStore: keys), .soniox(apiKey: "sx-key"))
    }

    func test_deepgram_usesTheStoredKeyAndSelectedModel() throws {
        try keys.save(key: "dg-key", for: .deepgram)
        XCTAssertEqual(
            ProviderBatchRoute.current(prefs: prefs(.deepgram), keyStore: keys),
            .deepgram(apiKey: "dg-key", model: "nova-3")
        )
    }

    func test_elevenLabs_usesTheStoredKey() throws {
        try keys.save(key: "el-key", for: .elevenLabs)
        XCTAssertEqual(ProviderBatchRoute.current(prefs: prefs(.elevenLabs), keyStore: keys), .elevenLabs(apiKey: "el-key"))
    }

    // Breaks if batch posts to another host than the realtime socket, keeps
    // the realtime path, or drops the user's model.
    func test_selfHosted_postsToTranscriptionsOnTheRealtimeHost() throws {
        let prefs = prefs(.selfHosted)
        prefs.selfHostedBaseURL = "wss://stt.example.com:8443/realtime"
        prefs.selfHostedModel = "whisper-large-v3"
        try keys.save(key: "sh-key", for: .selfHosted)
        XCTAssertEqual(
            ProviderBatchRoute.current(prefs: prefs, keyStore: keys),
            .selfHosted(
                apiKey: "sh-key",
                endpoint: URL(string: "https://stt.example.com:8443/v1/audio/transcriptions")!,
                model: "whisper-large-v3"
            )
        )
    }

    // Breaks if the key and the audio go out over plaintext HTTP. The
    // realtime path always upgrades the same base URL to TLS (`wss`).
    func test_selfHosted_plainHTTPBaseURL_isUpgradedToTLS() throws {
        let prefs = prefs(.selfHosted)
        prefs.selfHostedBaseURL = "http://localhost:9000"
        try keys.save(key: "sh-key", for: .selfHosted)
        XCTAssertEqual(
            ProviderBatchRoute.current(prefs: prefs, keyStore: keys),
            .selfHosted(
                apiKey: "sh-key",
                endpoint: URL(string: "https://localhost:9000/v1/audio/transcriptions")!,
                model: "gpt-4o-transcribe"
            )
        )
    }

    func test_selfHosted_withoutBaseURL_isNotConfigured() throws {
        try keys.save(key: "sh-key", for: .selfHosted)
        XCTAssertNil(ProviderBatchRoute.current(prefs: prefs(.selfHosted), keyStore: keys))
    }
}

/// One take, one provider: each adapter speaks its provider's documented
/// batch API with the same choices as that provider's realtime request.
/// Silence is an empty transcript; anything unreadable is an error.
final class ProviderBatchTranscriberTests: XCTestCase {
    private var session: URLSession!

    /// Three PCM16 samples, as the resilient-delivery rung hands them over.
    private let pcm = Data([0x01, 0x00, 0xFF, 0x7F, 0x00, 0x80])
    /// The same samples as a canonical 16 kHz mono PCM16 WAV, written out by
    /// hand, as `AudioRecorder` hands them over.
    private let wav = Data([
        0x52, 0x49, 0x46, 0x46, 0x2A, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45, // "RIFF", 42, "WAVE"
        0x66, 0x6D, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, // "fmt ", 16, PCM, mono
        0x80, 0x3E, 0x00, 0x00, 0x00, 0x7D, 0x00, 0x00, 0x02, 0x00, 0x10, 0x00, // 16000 Hz, 32000 B/s, 2, 16 bit
        0x64, 0x61, 0x74, 0x61, 0x06, 0x00, 0x00, 0x00,                         // "data", 6 bytes
        0x01, 0x00, 0xFF, 0x7F, 0x00, 0x80,
    ])
    private let fileID = "4e1f2b8a-0c3d-4a5b-9e6f-7a8b9c0d1e2f"
    private let jobID = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
    private let selfHostedEndpoint = URL(string: "https://stt.example.com:8443/v1/audio/transcriptions")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func transcriber(
        _ route: ProviderBatchRoute?,
        pollInterval: Duration = .milliseconds(1),
        jobTimeout: Duration = .seconds(30)
    ) -> ProviderBatchTranscriber {
        ProviderBatchTranscriber(route: { route }, session: session, pollInterval: pollInterval, jobTimeout: jobTimeout)
    }

    // MARK: Availability

    // Breaks if an unconfigured transcriber claims a recognizer (the ladder
    // would arm Retry on a call that can only fail) or sends the audio anywhere.
    func test_unconfigured_isUnavailable_andSendsNothing() async {
        let unconfigured = transcriber(nil)
        let available = await unconfigured.isAvailable()
        XCTAssertFalse(available)
        do {
            _ = try await unconfigured.transcribe(audio: pcm, language: "ru")
            XCTFail("an unconfigured transcriber must not produce a transcript")
        } catch {
            XCTAssertTrue(error is BatchTranscriptionUnavailable, "got \(error)")
        }
        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
    }

    // Breaks if the route is read once: AppDelegate keeps one transcriber for
    // the app's lifetime, so a provider chosen later would never be used.
    func test_routeIsReadOnEveryCall() async {
        let settings = await RouteBox()
        let live = ProviderBatchTranscriber(route: { settings.route }, session: session)
        let before = await live.isAvailable()
        await MainActor.run { settings.route = .elevenLabs(apiKey: "el-key") }
        let after = await live.isAvailable()
        XCTAssertFalse(before)
        XCTAssertTrue(after)
    }

    // MARK: Deepgram

    // Breaks if the request leaves Deepgram's pre-recorded contract or the
    // realtime request's parameters, or raw PCM goes out without a WAV header.
    func test_deepgram_postsTheTakeAsWAVToPrerecordedListen() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Self.deepgramBody(transcript: "Привет, мир.")) }

        let text = try await transcriber(.deepgram(apiKey: "dg-key", model: "nova-3"))
            .transcribe(audio: pcm, language: "ru")

        XCTAssertEqual(text, "Привет, мир.")
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.deepgram.com")
        XCTAssertEqual(request.url?.path, "/v1/listen")
        XCTAssertEqual(
            Self.query(request),
            ["model": "nova-3", "smart_format": "true", "punctuate": "true", "language": "ru"]
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token dg-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        XCTAssertEqual(StubURLProtocol.capturedBodies.first, wav)
    }

    // Omitting language defaults to English. Batch must use the same bounded
    // multilingual policy as realtime without detect_language model fallback.
    func test_deepgram_autoLanguage_usesMultilingualAndPreservesTheModel() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Self.deepgramBody(transcript: "Hello.")) }

        _ = try await transcriber(.deepgram(apiKey: "dg-key", model: "nova-3")).transcribe(audio: pcm, language: nil)

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(Self.query(request), ["model": "nova-3", "smart_format": "true", "punctuate": "true", "language": "multi"])
    }

    func test_deepgram_explicitEnglish_staysEnglish() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Self.deepgramBody(transcript: "Hello.")) }
        _ = try await transcriber(.deepgram(apiKey: "dg-key", model: "nova-3"))
            .transcribe(audio: pcm, language: "en")
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(Self.query(request)["language"], "en")
        XCTAssertEqual(Self.query(request)["model"], "nova-3")
    }

    func test_deepgram_invalidLanguageOrUnknownModelAuto_sendsNoAudio() async {
        for (model, language, expected) in [
            ("nova-3", "cy" as String?, DeepgramLanguageConfigurationError.unsupportedLanguage),
            ("custom-model", nil, DeepgramLanguageConfigurationError.automaticLanguageUnavailable),
        ] {
            do {
                _ = try await transcriber(.deepgram(apiKey: "dg-key", model: model))
                    .transcribe(audio: pcm, language: language)
                XCTFail("Invalid language setup must not upload audio")
            } catch {
                XCTAssertEqual(error as? DeepgramLanguageConfigurationError, expected)
            }
            XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
        }
    }

    // Breaks if a recorder WAV gets a second header: the provider would read
    // the first one as audio or reject the file.
    func test_wavInput_isSentUnchanged() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Self.deepgramBody(transcript: "Hello.")) }

        _ = try await transcriber(.deepgram(apiKey: "dg-key", model: "nova-3")).transcribe(audio: wav, language: nil)

        XCTAssertEqual(StubURLProtocol.capturedBodies.first, wav)
    }

    // Breaks if silence is reported as a failure: the ladder would show
    // "Couldn't deliver" and Retry would upload the same silence again.
    func test_deepgram_emptyTranscript_isSilence() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Self.deepgramBody(transcript: "")) }

        let text = try await transcriber(.deepgram(apiKey: "dg-key", model: "nova-3")).transcribe(audio: pcm, language: nil)

        XCTAssertEqual(text, "")
    }

    // Breaks if an HTTP error reads as an empty transcript (silence, no Retry)
    // or makes batch try another provider.
    func test_deepgram_httpError_throwsItsStatus_andTriesNoOtherProvider() async {
        StubURLProtocol.handler = { _ in (401, ["Content-Type": "application/json"], Self.json(["err_code": "INVALID_AUTH"])) }

        do {
            _ = try await transcriber(.deepgram(apiKey: "dg-key", model: "nova-3")).transcribe(audio: pcm, language: "ru")
            XCTFail("an HTTP error must not produce a transcript")
        } catch {
            XCTAssertEqual(error as? ProviderBatchTranscriptionError, .httpStatus(401))
        }
        XCTAssertEqual(StubURLProtocol.capturedRequests.compactMap { $0.url?.host }, ["api.deepgram.com"])
    }

    // MARK: ElevenLabs

    // Breaks if the request leaves the speech-to-text contract or the realtime
    // request's choices (no audio-event tags, no filler words).
    func test_elevenLabs_postsMultipartToSpeechToTextWithTheUsersKey() async throws {
        StubURLProtocol.handler = { _ in
            (200, [:], Self.json([
                "language_code": "ru", "language_probability": 0.98, "text": " Привет, мир. ", "words": [],
            ]))
        }

        let text = try await transcriber(.elevenLabs(apiKey: "el-key")).transcribe(audio: pcm, language: "ru")

        XCTAssertEqual(text, "Привет, мир.")
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "el-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let form = try MultipartForm(request, body: StubURLProtocol.capturedBodies[0])
        XCTAssertEqual(
            form.fields,
            ["model_id": "scribe_v2", "language_code": "ru", "tag_audio_events": "false", "no_verbatim": "true"]
        )
        XCTAssertEqual(form.files, [MultipartFile(name: "file", filename: "audio.wav", contentType: "audio/wav", content: wav)])
    }

    // Breaks if Auto input sends an empty language_code instead of leaving
    // detection to ElevenLabs.
    func test_elevenLabs_autoLanguage_sendsNoLanguageCode() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Self.json(["text": "Hello."])) }

        _ = try await transcriber(.elevenLabs(apiKey: "el-key")).transcribe(audio: pcm, language: nil)

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        let form = try MultipartForm(request, body: StubURLProtocol.capturedBodies[0])
        XCTAssertEqual(form.fields, ["model_id": "scribe_v2", "tag_audio_events": "false", "no_verbatim": "true"])
    }

    // Breaks if a 200 body without `text` reads as silence, which would drop
    // the take without Retry.
    func test_elevenLabs_bodyWithoutText_isAnError_notSilence() async {
        StubURLProtocol.handler = { _ in (200, [:], Self.json(["detail": "unexpected"])) }

        do {
            _ = try await transcriber(.elevenLabs(apiKey: "el-key")).transcribe(audio: pcm, language: nil)
            XCTFail("a body without text must not read as silence")
        } catch {
            XCTAssertEqual(error as? ProviderBatchTranscriptionError, .malformedResponse)
        }
    }

    // MARK: Self-hosted

    // Breaks if the request leaves the OpenAI-compatible transcription
    // contract or drops the user's model.
    func test_selfHosted_postsOpenAICompatibleMultipartWithBearerKey() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Self.json(["text": "Hello world."])) }

        let text = try await transcriber(.selfHosted(apiKey: "sh-key", endpoint: selfHostedEndpoint, model: "whisper-large-v3"))
            .transcribe(audio: pcm, language: "en")

        XCTAssertEqual(text, "Hello world.")
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, selfHostedEndpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sh-key")
        let form = try MultipartForm(request, body: StubURLProtocol.capturedBodies[0])
        XCTAssertEqual(form.fields, ["model": "whisper-large-v3", "language": "en", "response_format": "json"])
        XCTAssertEqual(form.files, [MultipartFile(name: "file", filename: "audio.wav", contentType: "audio/wav", content: wav)])
    }

    func test_selfHosted_autoLanguage_sendsNoLanguage() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Self.json(["text": "Hello world."])) }

        _ = try await transcriber(.selfHosted(apiKey: "sh-key", endpoint: selfHostedEndpoint, model: "whisper-large-v3"))
            .transcribe(audio: pcm, language: nil)

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        let form = try MultipartForm(request, body: StubURLProtocol.capturedBodies[0])
        XCTAssertEqual(form.fields, ["model": "whisper-large-v3", "response_format": "json"])
    }

    // MARK: Soniox

    // Breaks if the file flow (upload -> job -> poll -> transcript) leaves the
    // documented API, uses another model or key, or leaves the audio on Soniox.
    func test_soniox_transcribesThroughTheFileAPI_andDeletesTheAudioAfterwards() async throws {
        let deleted = deletions(2)
        serveSoniox(jobStatuses: ["queued", "processing", "completed"], deleted: deleted)

        let text = try await transcriber(.soniox(apiKey: "sx-key")).transcribe(audio: pcm, language: "ru")
        await fulfillment(of: [deleted], timeout: 2)

        XCTAssertEqual(text, "Привет, мир.")
        let requests = StubURLProtocol.capturedRequests
        XCTAssertEqual(requests.map(Self.line), [
            "POST https://api.soniox.com/v1/files",
            "POST https://api.soniox.com/v1/transcriptions",
            "GET https://api.soniox.com/v1/transcriptions/\(jobID)",
            "GET https://api.soniox.com/v1/transcriptions/\(jobID)",
            "GET https://api.soniox.com/v1/transcriptions/\(jobID)",
            "GET https://api.soniox.com/v1/transcriptions/\(jobID)/transcript",
            "DELETE https://api.soniox.com/v1/files/\(fileID)",
            "DELETE https://api.soniox.com/v1/transcriptions/\(jobID)",
        ])
        XCTAssertEqual(Set(requests.map { $0.value(forHTTPHeaderField: "Authorization") }), ["Bearer sx-key"])
        let upload = try MultipartForm(requests[0], body: StubURLProtocol.capturedBodies[0])
        XCTAssertEqual(upload.fields, [:])
        XCTAssertEqual(upload.files, [MultipartFile(name: "file", filename: "audio.wav", contentType: "audio/wav", content: wav)])
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies[1]) as? NSDictionary)
        XCTAssertEqual(job, ["model": "stt-async-v5", "file_id": fileID, "language_hints": ["ru", "en"]] as NSDictionary)
    }

    // Breaks if Auto input drops the "en" hint the realtime Soniox request
    // always sends, or sends an empty language.
    func test_soniox_autoLanguage_hintsEnglishOnly_likeRealtime() async throws {
        let deleted = deletions(2)
        serveSoniox(jobStatuses: ["completed"], deleted: deleted)

        _ = try await transcriber(.soniox(apiKey: "sx-key")).transcribe(audio: pcm, language: nil)
        await fulfillment(of: [deleted], timeout: 2)

        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies[1]) as? NSDictionary)
        XCTAssertEqual(job["language_hints"] as? [String], ["en"])
    }

    // Breaks if a completed job with no speech is reported as a failure
    // ("Couldn't deliver" plus a Retry that uploads the same silence).
    func test_soniox_completedJobWithoutSpeech_isSilence() async throws {
        let deleted = deletions(2)
        serveSoniox(jobStatuses: ["completed"], transcript: ["text": "", "tokens": []], deleted: deleted)

        let text = try await transcriber(.soniox(apiKey: "sx-key")).transcribe(audio: pcm, language: nil)
        await fulfillment(of: [deleted], timeout: 2)

        XCTAssertEqual(text, "")
    }

    // Breaks if a failed job reads as silence (no Retry) or leaves the audio
    // on Soniox.
    func test_soniox_failedJob_throws_andDeletesTheAudio() async {
        let deleted = deletions(2)
        serveSoniox(jobStatuses: ["error"], deleted: deleted)

        do {
            _ = try await transcriber(.soniox(apiKey: "sx-key")).transcribe(audio: pcm, language: nil)
            XCTFail("a failed job must not produce a transcript")
        } catch {
            XCTAssertEqual(error as? ProviderBatchTranscriptionError, .jobFailed)
        }
        await fulfillment(of: [deleted], timeout: 2)
        XCTAssertEqual(StubURLProtocol.capturedRequests.suffix(2).map(Self.line), [
            "DELETE https://api.soniox.com/v1/files/\(fileID)",
            "DELETE https://api.soniox.com/v1/transcriptions/\(jobID)",
        ])
    }

    // Breaks if the uploaded audio stays on Soniox when the job is rejected.
    func test_soniox_rejectedJob_deletesTheUploadedFile() async {
        let deleted = deletions(1)
        serveSoniox(jobStatuses: ["completed"], createJobStatus: 400, deleted: deleted)

        do {
            _ = try await transcriber(.soniox(apiKey: "sx-key")).transcribe(audio: pcm, language: nil)
            XCTFail("a rejected job must not produce a transcript")
        } catch {
            XCTAssertEqual(error as? ProviderBatchTranscriptionError, .httpStatus(400))
        }
        await fulfillment(of: [deleted], timeout: 2)
        XCTAssertEqual(StubURLProtocol.capturedRequests.map(Self.line), [
            "POST https://api.soniox.com/v1/files",
            "POST https://api.soniox.com/v1/transcriptions",
            "DELETE https://api.soniox.com/v1/files/\(fileID)",
        ])
    }

    // Breaks if a job Soniox never finishes is polled forever on the paths the
    // recovery deadline does not wrap (recorder fallback, agent voice), or if
    // the abandoned job stays on Soniox: it refuses (409) to delete a job that
    // is still processing, so the deletion is retried until the job stops.
    func test_soniox_jobThatNeverFinishes_timesOut_andDeletesTheAudio() async {
        let deleted = deletions(2)
        let jobDeletes = serveSoniox(jobStatuses: ["processing"], busyDeletes: 2, deleted: deleted)
        let soniox = transcriber(.soniox(apiKey: "sx-key"), pollInterval: .milliseconds(5), jobTimeout: .milliseconds(50))
        let pcm = pcm

        let outcome = await watchdog { try await soniox.transcribe(audio: pcm, language: nil) }

        XCTAssertEqual(outcome?.failure as? ProviderBatchTranscriptionError, .timedOut, "got \(String(describing: outcome))")
        await fulfillment(of: [deleted], timeout: 2)
        XCTAssertEqual(jobDeletes.value, 3)
    }

    // Breaks if the deletion of a job that never stops processing is retried
    // forever in the background.
    func test_soniox_deletionOfAJobThatNeverStops_isGivenUp() async throws {
        let deleted = deletions(1)
        let jobDeletes = serveSoniox(jobStatuses: ["processing"], busyDeletes: .max, deleted: deleted)
        let soniox = transcriber(.soniox(apiKey: "sx-key"), pollInterval: .milliseconds(5), jobTimeout: .milliseconds(50))
        let pcm = pcm

        let outcome = await watchdog { try await soniox.transcribe(audio: pcm, language: nil) }
        await fulfillment(of: [deleted], timeout: 2)
        try await Task.sleep(for: .milliseconds(500))
        let attempts = jobDeletes.value
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(outcome?.failure as? ProviderBatchTranscriptionError, .timedOut, "got \(String(describing: outcome))")
        XCTAssertGreaterThan(attempts, 1, "a job that is still processing is asked again")
        XCTAssertEqual(jobDeletes.value, attempts, "the retries must stop")
    }

    // Breaks if polling ignores task cancellation, so the 30 s recovery
    // deadline cannot end the take, or if cancellation skips the deletion.
    func test_soniox_recoveryDeadline_endsPolling_andStillDeletesTheAudio() async {
        let deleted = deletions(2)
        serveSoniox(jobStatuses: ["processing"], deleted: deleted)
        let soniox = transcriber(.soniox(apiKey: "sx-key"), pollInterval: .milliseconds(5))
        let pcm = pcm

        let outcome = await watchdog {
            try await AppDelegate.withBatchRecoveryDeadline(Self.shortDeadline()) {
                try await soniox.transcribe(audio: pcm, language: nil)
            }
        }

        XCTAssertTrue(outcome?.failure is AppDelegate.BatchRecoveryTimeout, "got \(String(describing: outcome))")
        await fulfillment(of: [deleted], timeout: 2)
    }

    // MARK: Deadline

    // Breaks if the transcriber waits in a way cancellation cannot end (a
    // blocking wait, a swallowed CancellationError): the 30 s recovery
    // deadline could not unwedge a provider that never answers.
    func test_providerThatNeverAnswers_isEndedByTheRecoveryDeadline() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NeverAnsweringURLProtocol.self]
        let silentNetwork = URLSession(configuration: config)
        defer { silentNetwork.invalidateAndCancel() }
        let deepgram = ProviderBatchTranscriber(route: { .deepgram(apiKey: "dg-key", model: "nova-3") }, session: silentNetwork)
        let pcm = pcm

        let outcome = await watchdog {
            try await AppDelegate.withBatchRecoveryDeadline(Self.shortDeadline()) {
                try await deepgram.transcribe(audio: pcm, language: nil)
            }
        }

        XCTAssertTrue(outcome?.failure is AppDelegate.BatchRecoveryTimeout, "got \(String(describing: outcome))")
    }

    // MARK: Helpers

    /// A Soniox account: the upload, the job, then `jobStatuses` in order (the
    /// last one repeats) and the transcript. The first `busyDeletes` deletions
    /// of the job answer 409 (still processing), as Soniox does. Every
    /// successful deletion fulfils `deleted`. Returns the count of job
    /// deletion attempts.
    @discardableResult
    private func serveSoniox(
        jobStatuses: [String],
        transcript: [String: Any] = ["text": "Привет, мир.", "tokens": [["text": "Привет, мир."]]],
        createJobStatus: Int = 201,
        busyDeletes: Int = 0,
        deleted: XCTestExpectation
    ) -> Counter {
        let fileID = fileID
        let jobID = jobID
        let jobDeletes = Counter()
        var polls = 0
        StubURLProtocol.handler = { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", "/v1/files"):
                return (201, [:], Self.json(["id": fileID]))
            case ("POST", "/v1/transcriptions"):
                guard createJobStatus == 201 else { return (createJobStatus, [:], Self.json(["message": "invalid request"])) }
                return (201, [:], Self.json(["id": jobID, "status": "queued"]))
            case ("GET", "/v1/transcriptions/\(jobID)"):
                defer { polls += 1 }
                return (200, [:], Self.json(["id": jobID, "status": jobStatuses[min(polls, jobStatuses.count - 1)]]))
            case ("GET", "/v1/transcriptions/\(jobID)/transcript"):
                return (200, [:], Self.json(transcript))
            case ("DELETE", "/v1/transcriptions/\(jobID)"):
                guard jobDeletes.increment() > busyDeletes else {
                    return (409, [:], Self.json(["message": "The transcription is still processing."]))
                }
                deleted.fulfill()
                return (204, [:], Data())
            case ("DELETE", "/v1/files/\(fileID)"):
                deleted.fulfill()
                return (204, [:], Data())
            default:
                return (404, [:], Data())
            }
        }
        return jobDeletes
    }

    private func deletions(_ count: Int) -> XCTestExpectation {
        let deleted = expectation(description: "remote audio deleted")
        deleted.expectedFulfillmentCount = count
        return deleted
    }

    /// Runs `body` with a time limit, so a regression that hangs fails its
    /// test instead of wedging the suite. `nil` = still running.
    private func watchdog(_ body: @escaping @Sendable () async throws -> String) async -> Result<String, Error>? {
        let finished = expectation(description: "finished")
        let outcome = OutcomeBox()
        Task {
            do { outcome.set(.success(try await body())) } catch { outcome.set(.failure(error)) }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        return outcome.value
    }

    private static func shortDeadline() -> AppDelegate.BatchRecoveryDeadline {
        AppDelegate.BatchRecoveryDeadline(seconds: 0.2) { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    }

    private static func deepgramBody(transcript: String) -> Data {
        json(["results": ["channels": [["alternatives": [["transcript": transcript, "confidence": 0.99]]]]]])
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func query(_ request: URLRequest) -> [String: String] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private static func line(_ request: URLRequest) -> String {
        "\(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")"
    }
}

/// Production wiring: the batch rung, manual Retry, the recorder fallback and
/// the agent's batch voice path all get the provider batch transcriber.
final class ProviderBatchWiringTests: XCTestCase {
    // Breaks if production keeps the no-op seam: the batch rung, Retry and the
    // recorder fallback would still have no recognizer.
    func test_appDelegateBindsTheProviderBatchTranscriber() throws {
        XCTAssertTrue(try appDelegateSource().contains(
            "private let batchTranscriber: any BatchTranscribing = ProviderBatchTranscriber()"
        ))
    }

    // Breaks if the agent keeps the hermetic default, so its batch voice path
    // can never transcribe.
    func test_agentControllerGetsTheSameBatchTranscriber() throws {
        XCTAssertTrue(try appDelegateSource().contains(
            "audioTranscriber: BatchAgentAudioTranscriber(batch: batchTranscriber)"
        ))
    }

    private func appDelegateSource() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return try String(
                    contentsOf: url.appendingPathComponent("Sources/Sidekey/AppDelegate.swift"),
                    encoding: .utf8
                )
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "ProviderBatchWiringTests", code: 1)
    }
}

// MARK: - Test doubles

@MainActor
private final class RouteBox {
    var route: ProviderBatchRoute?
}

/// Accepts every request and never answers, like a provider that stopped
/// responding. Only cancellation ends the request.
private final class NeverAnsweringURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

/// Counted on URL-loading threads, read by the test.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Returns the new count.
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<String, Error>?

    var value: Result<String, Error>? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ outcome: Result<String, Error>) {
        lock.lock(); defer { lock.unlock() }
        stored = outcome
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

private struct MultipartFile: Equatable {
    let name: String
    let filename: String
    let contentType: String
    let content: Data
}

/// A multipart/form-data body split on the boundary its request declares.
private struct MultipartForm {
    private(set) var fields: [String: String] = [:]
    private(set) var files: [MultipartFile] = []

    init(_ request: URLRequest, body: Data) throws {
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let prefix = "multipart/form-data; boundary="
        XCTAssertTrue(contentType.hasPrefix(prefix), "Content-Type: \(contentType)")
        let delimiter = Data("--\(contentType.dropFirst(prefix.count))".utf8)
        let crlf = Data("\r\n".utf8)
        var bounds: [Range<Data.Index>] = []
        var cursor = body.startIndex
        while let found = body.range(of: delimiter, in: cursor..<body.endIndex) {
            bounds.append(found)
            cursor = found.upperBound
        }
        let closing = try XCTUnwrap(bounds.last, "no boundary in the body")
        XCTAssertEqual(Data(body[closing.upperBound...]), Data("--\r\n".utf8), "unterminated multipart body")
        for (open, close) in zip(bounds, bounds.dropFirst()) {
            let part = body[open.upperBound..<close.lowerBound]
            XCTAssertTrue(part.starts(with: crlf) && Data(part.suffix(2)) == crlf, "malformed part")
            let inner = part.dropFirst(2).dropLast(2)
            let split = try XCTUnwrap(inner.range(of: Data("\r\n\r\n".utf8)), "part without headers")
            let headers = String(decoding: inner[inner.startIndex..<split.lowerBound], as: UTF8.self)
            let content = Data(inner[split.upperBound...])
            let name = try XCTUnwrap(Self.parameter("name", in: headers), headers)
            if let filename = Self.parameter("filename", in: headers) {
                let type = headers.components(separatedBy: "\r\n")
                    .first { $0.hasPrefix("Content-Type: ") }?
                    .dropFirst("Content-Type: ".count)
                files.append(MultipartFile(name: name, filename: filename, contentType: type.map(String.init) ?? "", content: content))
            } else {
                fields[name] = String(decoding: content, as: UTF8.self)
            }
        }
    }

    private static func parameter(_ key: String, in headers: String) -> String? {
        guard let start = headers.range(of: "; \(key)=\"") else { return nil }
        let rest = headers[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
