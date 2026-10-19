import SwiftUI

/// Editorial guidance only: opening hints never checks balances or changes a route.
/// WHY: .project-docs/decisions/2026-10-19-api-hints.md
@MainActor
struct APIHintsView: View {
    let onAddKey: () -> Void
    @State private var isExpanded: Bool

    init(initiallyExpanded: Bool = false, onAddKey: @escaping () -> Void) {
        self.onAddKey = onAddKey
        self._isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        MacCard {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Exodia is free. Provider free tiers and included credits can cover your AI usage within their limits.")
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text2)

                    ForEach(Self.hints) { hint in
                        hintRow(hint)
                    }

                    Text("Offers checked October 19, 2026. Eligibility, quotas and availability can change. Check the provider's terms and billing settings before use.")
                        .font(.system(size: 11))
                        .foregroundStyle(MacSettingsTheme.text2)

                    Button("Add API key", action: onAddKey)
                        .controlSize(.small)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(MacSettingsTheme.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("API hints")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MacSettingsTheme.text)
                        Text("Free tiers & included credits")
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.text2)
                    }
                }
            }
            .padding(14)
        }
    }

    private func hintRow(_ hint: Hint) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(hint.provider)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                Text(hint.allowance)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            Text(hint.detail)
                .font(.system(size: 12))
                .foregroundStyle(MacSettingsTheme.text2)
            Link(destination: hint.url) {
                Label(hint.linkTitle, systemImage: "arrow.up.right")
                    .font(.system(size: 11.5))
            }
            .accessibilityHint("Opens the provider's website in your browser")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private struct Hint: Identifiable {
        let provider: String
        let allowance: String
        let detail: String
        let linkTitle: String
        let url: URL
        var id: String { provider }
    }

    // Keep amounts and the visible verification date together when refreshing offers.
    private static let hints: [Hint] = [
        Hint(
            provider: "Deepgram",
            allowance: "$200 starter credit",
            detail: "New accounts receive a one-time $200 API credit, with no card required to start. Add a Deepgram key and choose a Deepgram model for speech recognition.",
            linkTitle: "Deepgram credit details",
            url: URL(string: "https://deepgram.com/pricing")!
        ),
        Hint(
            provider: "ElevenLabs",
            allowance: "Free monthly allowance",
            detail: "The Free plan includes 10,000 credits each month and API access. Check the Scribe speech-to-text allowance: realtime and batch audio have different quotas. Add an ElevenLabs key and choose Scribe for speech recognition.",
            linkTitle: "ElevenLabs API pricing",
            url: URL(string: "https://elevenlabs.io/pricing/api")!
        ),
        Hint(
            provider: "OpenRouter",
            allowance: "Free models",
            detail: "Choose a model ending in :free for text cleanup, meeting notes or the agent. The free tier allows 50 requests a day and 20 a minute. Agent turns may use several requests; availability and tool support vary by model.",
            linkTitle: "Browse OpenRouter free models",
            url: URL(string: "https://openrouter.ai/models?max_price=0")!
        ),
        Hint(
            provider: "Claude Max",
            allowance: "Included with a paid plan",
            detail: "Max 5x includes $100 and Max 20x $200 in API credit per month. After seven days on the plan, link a Console organization in Claude Settings → Billing. Add that organization's Anthropic key here and select an Anthropic model for Agent. Unused credits expire each cycle; they do not fund OpenRouter requests.",
            linkTitle: "Claim Claude Max API credits",
            url: URL(string: "https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-and-team-plans")!
        ),
    ]
}
