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
