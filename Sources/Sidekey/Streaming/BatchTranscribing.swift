import Foundation

/// One-shot transcription of an already-captured audio buffer. The Drop
/// recorder fallback, the resilient-delivery batch rung, and the agent's
/// batch voice path all go through this seam.
protocol BatchTranscribing: Sendable {
    /// Whether a batch transcription can run right now.
    func isAvailable() async -> Bool

    /// Transcribe a 16 kHz mono PCM16 buffer. Callers hand over either raw
    /// PCM or a canonical WAV file (`AudioRecorder` output).
    func transcribe(audio: Data, language: String?) async throws -> String
}

/// Thrown by `UnavailableBatchTranscriber`: there is no batch recognizer.
struct BatchTranscriptionUnavailable: Error, Equatable {}

/// Production binding while no batch recognizer exists. On-device Parakeet
/// was removed and provider batch APIs are not wired yet, so the batch rung
/// is skipped: a degraded Drop goes to the raw partial, then to
/// "Couldn't deliver". WHY: .project-docs/decisions/2026-10-18-remove-local-models.md
struct UnavailableBatchTranscriber: BatchTranscribing {
    func isAvailable() async -> Bool { false }

    func transcribe(audio: Data, language: String?) async throws -> String {
        throw BatchTranscriptionUnavailable()
    }
}
