import SwiftUI

/// Editorial guidance only: opening hints never checks balances or changes a route.
/// WHY: .project-docs/decisions/2026-10-19-api-hints.md
@MainActor
struct APIHintsView: View {
    let onAddKey: () -> Void
    let onClose: () -> Void
    var embedded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("API hints")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                Text("Free tiers and credits for the providers you connect.")
                    .font(.system(size: 13))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            .padding(24)
            .padding(.bottom, 2)

            ScrollView {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        offerCard(Self.hints[0])
                        offerCard(Self.hints[1])
                    }
                    GridRow {
                        offerCard(Self.hints[2])
                        offerCard(Self.hints[3])
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            footer
        }
        .background(embedded ? MacSettingsTheme.bgCard : Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onClose)
    }

    private func offerCard(_ hint: Hint) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ProviderBrandIcon(assetName: hint.assetName, size: 18, color: MacSettingsTheme.text)
                    .frame(width: 32, height: 32)
                    .background(MacSettingsTheme.hover, in: RoundedRectangle(cornerRadius: 8))
                Text(hint.provider)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                Spacer(minLength: 4)
                if hint.requiresPaidPlan {
                    Text("Paid plan")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(MacSettingsTheme.hover, in: Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(hint.allowance)
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(MacSettingsTheme.text)
                Text(hint.cadence)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            .padding(.top, 17)

            Text(hint.detail)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 11)

            Spacer(minLength: 16)

            Link(destination: hint.url) {
                HStack(spacing: 4) {
                    Text("View offer")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            .accessibilityLabel("\(hint.provider) offer details")
            .accessibilityHint("Opens the provider's website in your browser")
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity, alignment: .topLeading)
        .background(MacSettingsTheme.bgCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a provider key, then choose its model for a feature in Models.")
                .font(.system(size: 11.5))
                .foregroundStyle(MacSettingsTheme.text2)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Checked October 19, 2026")
                    Text("Provider terms, limits and billing settings apply.")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(MacSettingsTheme.text2)
                Spacer(minLength: 16)
                Button("Add API key", action: onAddKey)
                    .buttonStyle(.bordered)
                if !embedded {
                    Button("Done", action: onClose)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .overlay(alignment: .top) {
            Rectangle().fill(MacSettingsTheme.sep).frame(height: 0.5)
        }
    }

    private struct Hint {
        let provider: String
        let assetName: String
        let allowance: String
        let cadence: String
        let detail: String
        let url: URL
        var requiresPaidPlan = false
    }

    // Keep amounts and the visible verification date together when refreshing offers.
    private static let hints: [Hint] = [
        Hint(
            provider: "Deepgram",
            assetName: "deepgram",
            allowance: "$200",
            cadence: "one-time starter credit",
            detail: "Speech recognition credit for new accounts. No card needed to start.",
            url: URL(string: "https://deepgram.com/pricing")!
        ),
        Hint(
            provider: "ElevenLabs",
            assetName: "elevenlabs",
            allowance: "10,000",
            cadence: "free credits each month",
            detail: "The Free plan includes API access. Check Scribe's allowance: realtime and batch audio have different quotas.",
            url: URL(string: "https://elevenlabs.io/pricing/api")!
        ),
        Hint(
            provider: "OpenRouter",
            assetName: "openrouter",
            allowance: "50 / day",
            cadence: "free model requests",
            detail: "Choose a :free model. Limit: 20 requests a minute. Tool support and availability vary; agent turns may use several requests.",
            url: URL(string: "https://openrouter.ai/models?max_price=0")!
        ),
        Hint(
            provider: "Claude Max",
            assetName: "claude-code",
            allowance: "$100–200",
            cadence: "API credit each month",
            detail: "Max 5x: $100; Max 20x: $200. After seven days, link a Console organization in Claude's billing settings. Use its Anthropic key for Agent. Credits expire each cycle.",
            url: URL(string: "https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-and-team-plans")!,
            requiresPaidPlan: true
        ),
    ]
}
