import Foundation

/// Drop output selector, stored locally in `UserPreferencesCache`.
///
/// - `fast`: the realtime transcript is pasted as-is (filler stripping only,
///   no LLM cleanup).
/// - `smart`: the transcript runs through the configured cleanup LLM
///   (OpenRouter or a custom OpenAI-compatible endpoint)
///   before it is pasted. An unavailable route or failed cleanup retains the
///   transcript and offers Retry; it never silently substitutes Fast output.
///
/// Brand-new users default to `fast`.
enum TranscriptionMode: String, Codable, CaseIterable, Equatable, Sendable {
    case fast
    case smart
}
