import Foundation

/// Models the app picks itself, because they are not a user choice: the
/// recorded-audio model of a provider whose real-time route names a streaming
/// model. Anything the user picks lives in a `FeatureRoute`.
enum ModelRegistry {
    /// Soniox async (file) transcription, the batch counterpart of `stt-rt-*`.
    /// The same model `SonioxFileAPI` and the meeting transcriber send.
    static let sonioxRecordedModel = "stt-async-v5"
    /// ElevenLabs Scribe v2 for recorded audio; `scribe_v2_realtime` is the
    /// streaming model and is not accepted by the speech-to-text endpoint.
    static let elevenLabsRecordedModel = "scribe_v2"
}

/// A model the app ships knowledge about: what it is for, and whether the
/// provider can label speakers with it. "Verified" means the app's adapters
/// are written and checked against this model.
struct RegistryModel: Equatable, Sendable {
    let kind: AIProviderKind
    let id: String
    let uses: Set<ModelUse>
    let diarization: Bool
}

extension ModelRegistry {
    static let models: [RegistryModel] = [
        RegistryModel(kind: .soniox, id: "stt-rt-v5", uses: [.realtimeSTT], diarization: false),
        RegistryModel(kind: .soniox, id: sonioxRecordedModel, uses: [.asyncSTT], diarization: true),
        RegistryModel(kind: .deepgram, id: "nova-3", uses: [.realtimeSTT], diarization: false),
        RegistryModel(kind: .elevenLabs, id: "scribe_v2_realtime", uses: [.realtimeSTT], diarization: false),
        RegistryModel(kind: .elevenLabs, id: elevenLabsRecordedModel, uses: [.asyncSTT], diarization: false),
        RegistryModel(kind: .openRouter, id: "google/gemini-3.8-flash", uses: [.chat], diarization: false),
        RegistryModel(kind: .openRouter, id: "anthropic/claude-sonnet-5.5", uses: [.chat, .chatWithTools], diarization: false),
    ]

    /// Smallest context window a model needs for Meeting notes (N) and for the
    /// Agent (M), in tokens. Smaller ones get a warning, not a ban.
    static let meetingNotesMinContext = 64_000
    static let agentMinContext = 64_000

    /// True when the app ships this model for this use.
    static func isVerified(_ id: String, kind: AIProviderKind, use: ModelUse) -> Bool {
        models.contains { $0.kind == kind && $0.id == id && $0.uses.contains(use) }
    }

    /// The model offered first for a feature on a provider, or `nil` when the
    /// provider does not serve the feature or has no model the app chooses
    /// (a user's own server). Exhaustive on purpose: a new provider kind has
    /// to decide its cells here.
    static func recommended(for feature: AIFeature, kind: AIProviderKind) -> String? {
        switch kind {
        case .soniox:
            switch feature {
            case .dropFast, .dropSmart, .agentVoice, .voiceSearch: return "stt-rt-v5"
            case .meetings: return sonioxRecordedModel
            case .dropSmartCleanup, .meetingNotes, .agent: return nil
            }
        case .deepgram:
            switch feature {
            case .dropFast, .dropSmart, .agentVoice, .voiceSearch, .meetings: return "nova-3"
            case .dropSmartCleanup, .meetingNotes, .agent: return nil
            }
        case .elevenLabs:
            switch feature {
            case .dropFast, .dropSmart, .agentVoice, .voiceSearch, .meetings: return "scribe_v2_realtime"
            case .dropSmartCleanup, .meetingNotes, .agent: return nil
            }
        case .openRouter:
            switch feature {
            case .dropSmartCleanup, .meetingNotes: return "google/gemini-3.8-flash"
            case .agent: return "anthropic/claude-sonnet-5.5"
            case .dropFast, .dropSmart, .meetings, .agentVoice, .voiceSearch: return nil
            }
        case .openAICompatible:
            return nil
        }
    }

    /// Bumped when an adapter changes in a way that makes an earlier "checked
    /// when picked" result stale. Every adapter is at 1 for now.
    static func adapterVersion(_ kind: AIProviderKind, _ use: ModelUse) -> Int {
        1
    }

    /// Why the app cannot run a model it can see in a catalog, or `nil`.
    static func knownUnsupportedReason(_ id: String, kind: AIProviderKind, use: ModelUse) -> String? {
        switch kind {
        case .deepgram:
            return id.hasPrefix("flux-") ? "needs Deepgram's v2 streaming API" : nil
        case .soniox, .elevenLabs, .openRouter, .openAICompatible:
            return nil
        }
    }
}
