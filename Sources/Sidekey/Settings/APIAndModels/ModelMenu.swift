import SwiftUI

/// The one model dropdown of a feature row: models grouped by the providers
/// that have a key and can serve the feature. Picking a model is the only way
/// to pick a provider.
@MainActor
struct ModelMenu: View {
    @ObservedObject var viewModel: APIAndModelsViewModel
    let feature: AIFeature
    let label: String
    let onAddKey: () -> Void
    let onOtherModel: () -> Void
    var width: CGFloat? = nil

    var body: some View {
        let sections = viewModel.sections(for: feature)
        MacMenu(title: label, minWidth: width ?? 90, maxWidth: width ?? 300) {
            if sections.isEmpty {
                if let hint = viewModel.missingProviderHint(for: feature) {
                    Button(hint, action: onAddKey)
                }
            } else {
                ForEach(sections, id: \.account) { section in
                    sectionItems(section)
                }
                Divider()
                Button("Refresh models") { Task { await viewModel.refreshModels() } }
                Button("Other model ID…", action: onOtherModel)
            }
        }
        .accessibilityLabel("Model for \(feature.title)")
    }

    @ViewBuilder
    private func sectionItems(_ section: PickerSection) -> some View {
        Section(section.refreshFailed ? "\(section.title) · Couldn't refresh" : section.title) {
            ForEach(section.options, id: \.model) { option in
                Button {
                    Task { await viewModel.select(model: option.model, account: section.account, for: feature) }
                } label: {
                    if option.isSelected {
                        Label(optionTitle(option), systemImage: "checkmark")
                    } else {
                        Text(optionTitle(option))
                    }
                }
                .disabled(isUnsupported(option))
            }
        }
    }

    /// Just the model ID; a short hint ("with speakers") stays on the same line.
    /// A new model is still checked when picked, without saying so in every item.
    private func optionTitle(_ option: PickerOption) -> String {
        option.hint.map { "\(option.model) — \($0)" } ?? option.model
    }

    private func isUnsupported(_ option: PickerOption) -> Bool {
        if case .notSupported = option.state { return true }
        return false
    }
}

/// "Other model ID…": a model the provider does not list, or a provider with
/// no model list. The ID goes through the same check as any new model.
@MainActor
struct OtherModelSheet: View {
    let feature: AIFeature
    let accounts: [(account: ProviderAccount, title: String)]
    let onUse: (ProviderAccount, String) -> Void
    let onCancel: () -> Void

    @State private var modelID = ""
    @State private var selected: ProviderAccount?

    init(feature: AIFeature, accounts: [(ProviderAccount, String)],
         onUse: @escaping (ProviderAccount, String) -> Void, onCancel: @escaping () -> Void) {
        self.feature = feature
        self.accounts = accounts.map { (account: $0.0, title: $0.1) }
        self.onUse = onUse
        self.onCancel = onCancel
        _selected = State(initialValue: accounts.first?.0)
    }

    private var trimmedID: String { modelID.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Other model ID for \(feature.title)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text)
            if accounts.count > 1 {
                HStack {
                    Text("Account").font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                    Spacer()
                    MacPopup(items: accounts.map { .init(value: Optional($0.account), label: $0.title) },
                             selection: $selected, maxWidth: 260)
                        .accessibilityLabel("Account")
                }
            }
            MacField(placeholder: "Model ID", text: $modelID, monospaced: true)
            Text("It is checked when picked. If the check fails, the current model stays.")
                .font(.caption).foregroundStyle(MacSettingsTheme.text2)
            HStack {
                Spacer()
                MacButton(title: "Not now", style: .default, action: onCancel)
                MacButton(title: "Use", style: .primary, isEnabled: selected != nil && !trimmedID.isEmpty) {
                    if let selected { onUse(selected, trimmedID) }
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
