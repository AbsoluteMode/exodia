import Foundation

enum TranscriptionFactoryError: Error, Equatable {
    case missingKey
    case missingBaseURL
    /// No transcription provider has been chosen yet (Settings -> Models).
    /// A former on-device user lands here too: their audio never left the Mac.
    case notConfigured
}

/// Turns the current isolation-level config into a `StreamingSessionRunning`:
/// a `DirectProviderStreamingSession` driving the per-provider BYOK adapter
/// (openAI/selfHosted -> OpenAI Realtime standard; deepgram/soniox/elevenLabs
/// -> their native client-direct adapters).
@MainActor
struct TranscriptionSessionFactory {
    let prefs: SelfKeyPreferences
    let keyStore: BYOKKeyStore
    let vocab: VocabularyCache

    /// Build the session for the current isolation level. `resilient` enables
    /// degraded-turn batch recovery and must be `true` ONLY for the Drop flow;
    /// agent-voice and Google-search pass `false` so they can never resolve
    /// `.degraded` (their handlers treat it as a no-op, which would silently
    /// drop dictation).
    func make(
        language: String?,
        resilient: Bool = false
    ) throws -> StreamingSessionRunning {
        switch prefs.transcriptionLevel {
        case nil:
            throw TranscriptionFactoryError.notConfigured
        case .yourKey:
            let provider = prefs.selectedProvider
            guard let key = (try? keyStore.read(for: provider)), !key.isEmpty else {
                throw TranscriptionFactoryError.missingKey
            }
            // The user's per-provider model selection (Models UI); falls back to
            // the provider default, and to `selfHostedModel` for self-hosted.
            let model = prefs.transcriptionModel(for: provider)
            let adapter: BYOKTranscriptionAdapter
            switch provider {
            case .openAI, .selfHosted:
                let baseURL = provider == .selfHosted ? prefs.selfHostedBaseURL : nil
                if provider == .selfHosted, (baseURL?.isEmpty ?? true) {
                    throw TranscriptionFactoryError.missingBaseURL
                }
                adapter = OpenAIRealtimeAdapter(apiKey: key, baseURL: baseURL, model: model)
            case .deepgram:
                adapter = DeepgramBYOKAdapter(apiKey: key, model: model)
            case .soniox:
                adapter = SonioxBYOKAdapter(apiKey: key, model: model)
            case .elevenLabs:
                adapter = ElevenLabsBYOKAdapter(apiKey: key, model: model)
            }
            return DirectProviderStreamingSession(
                audioEngine: StreamingAudioEngine(),
                adapter: adapter,
                language: language,
                terms: vocab.terms,
                resilient: resilient
            )
        }
    }
}
