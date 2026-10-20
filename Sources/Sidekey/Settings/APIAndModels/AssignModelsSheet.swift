import SwiftUI

/// "Use <Provider> for": the features the proposal offers, each with its
/// recommended model. Nothing is assigned until Use.
@MainActor
struct AssignModelsSheet: View {
    let proposal: AssignProposal
    let onUse: (Set<AIFeature>) -> Void
    let onNotNow: () -> Void

    @State private var selected: Set<AIFeature>

    init(proposal: AssignProposal, onUse: @escaping (Set<AIFeature>) -> Void, onNotNow: @escaping () -> Void) {
        self.proposal = proposal
        self.onUse = onUse
        self.onNotNow = onNotNow
        _selected = State(initialValue: Set(proposal.items.map(\.feature)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(proposal.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text)
            MacCard {
                ForEach(Array(proposal.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { MacRowSeparator() }
                    MacRow(
                        title: item.feature.title,
                        subtitle: item.model,
                        leading: {
                            MacSwitch(isOn: Binding(
                                get: { selected.contains(item.feature) },
                                set: { isOn in
                                    if isOn { selected.insert(item.feature) } else { selected.remove(item.feature) }
                                }
                            ), label: item.feature.title)
                        },
                        trailing: { ProviderKindIcon(kind: item.account.kind) }
                    )
                }
            }
            HStack(spacing: 8) {
                Spacer()
                MacButton(title: "Not now", style: .default, action: onNotNow)
                MacButton(title: "Use", style: .primary, isEnabled: !selected.isEmpty) { onUse(selected) }
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
