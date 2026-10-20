import SwiftUI

/// Provider identities stay visible even before the first key is added. The
/// selected square opens its form directly below its row, at the full width.
@MainActor
struct ProviderKeyTiles: View {
    enum Target: Hashable {
        case provider(AIProviderKind)
        case server(ProviderAccount)
    }

    @ObservedObject var viewModel: APIAndModelsViewModel
    @State private var expanded: Target?
    @State private var busy = false
    @FocusState private var focused: Target?

    init(viewModel: APIAndModelsViewModel, initiallyExpanded: Target? = nil) {
        self.viewModel = viewModel
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var targets: [Target] {
        AIProviderKind.allCases.map(Target.provider)
            + viewModel.chips.compactMap { chip in
                if case .server = chip.account { return .server(chip.account) }
                return nil
            }
    }

    var body: some View {
        let items = targets
        ProviderGrid(tileCount: items.count, expandedIndex: expanded.flatMap { items.firstIndex(of: $0) }) {
            ForEach(items, id: \.self) { target in tile(target) }
            if let expanded {
                ProviderKeyForm(viewModel: viewModel, kind: kind(expanded), account: account(expanded),
                                onBusyChanged: { busy = $0 }, onClose: close)
                    .id(expanded)
            }
        }
        .onKeyPress(.escape) {
            guard expanded != nil, !busy else { return .ignored }
            close()
            return .handled
        }
    }

    private func tile(_ target: Target) -> some View {
        let provider = kind(target)
        let chip = account(target).flatMap { account in viewModel.chips.first { $0.account == account } }
        let selected = expanded == target
        return Button {
            expanded = selected ? nil : target
        } label: {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: 9) {
                        ProviderKindIcon(kind: provider, size: 28)
                        Text(chip?.title ?? (provider == .openAICompatible ? "Custom server" : provider.displayName))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Text(provider.keyTileDetail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.text2)
                        Text(chip?.statusText ?? "Add API key")
                            .font(.system(size: 11))
                            .foregroundStyle(chip == nil && !selected ? MacSettingsTheme.accent : MacSettingsTheme.text2)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(12)
                }
                .foregroundStyle(MacSettingsTheme.text)
                .background(selected ? MacSettingsTheme.accent.opacity(0.07) : MacSettingsTheme.fieldBg,
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(selected || focused == target ? MacSettingsTheme.accent : MacSettingsTheme.sep,
                                      lineWidth: selected || focused == target ? 1.5 : 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(APIModelFeedbackStyle(cornerRadius: 12))
        .disabled(busy)
        .focused($focused, equals: target)
        .accessibilityLabel(chip?.title ?? provider.displayName)
        .accessibilityValue("\(chip?.statusText ?? "No key"), \(selected ? "Expanded" : "Collapsed")")
        .accessibilityHint(selected ? "Close key settings" : "Open key settings")
    }

    private func kind(_ target: Target) -> AIProviderKind {
        switch target {
        case .provider(let kind): return kind
        case .server(let account): return account.kind
        }
    }

    private func account(_ target: Target) -> ProviderAccount? {
        switch target {
        case .provider(let kind): return viewModel.account(for: kind)
        case .server(let account): return account
        }
    }

    private func close() {
        focused = expanded
        expanded = nil
    }
}

/// Layout computes the column count directly from the proposed width. Resizing
/// never recreates the form or loses an entered key while a request is pending.
private struct ProviderGrid: Layout {
    let tileCount: Int
    let expandedIndex: Int?
    private let spacing: CGFloat = 12

    private func metrics(width: CGFloat, subviews: Subviews) -> (columns: Int, side: CGFloat, formHeight: CGFloat) {
        let columns = width >= 700 ? 4 : (width >= 450 ? 3 : 2)
        let side = max(1, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let height = expandedIndex != nil && subviews.count > tileCount
            ? subviews[tileCount].sizeThatFits(.init(width: width, height: nil)).height : 0
        return (columns, side, height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 516)
        let m = metrics(width: width, subviews: subviews)
        let rows = (tileCount + m.columns - 1) / m.columns
        let height = CGFloat(rows) * m.side + CGFloat(max(0, rows - 1)) * spacing
            + (expandedIndex == nil ? 0 : m.formHeight + spacing)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(width: bounds.width, subviews: subviews)
        let expandedRow = expandedIndex.map { $0 / m.columns }
        for index in 0..<min(tileCount, subviews.count) {
            let row = index / m.columns
            let extra = expandedRow.map { row > $0 ? m.formHeight + spacing : 0 } ?? 0
            subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(index % m.columns) * (m.side + spacing),
                                              y: bounds.minY + CGFloat(row) * (m.side + spacing) + extra),
                                  anchor: .topLeading, proposal: .init(width: m.side, height: m.side))
        }
        if let expandedRow, subviews.count > tileCount {
            subviews[tileCount].place(at: CGPoint(x: bounds.minX,
                                                 y: bounds.minY + CGFloat(expandedRow + 1) * (m.side + spacing)),
                                     anchor: .topLeading, proposal: .init(width: bounds.width, height: m.formHeight))
        }
    }
}

extension AIProviderKind {
    var keyTileDetail: String {
        switch self {
        case .soniox, .deepgram, .elevenLabs: return "Speech recognition"
        case .openRouter, .openAI, .anthropic: return "Language models"
        case .openAICompatible: return "Your own endpoint"
        }
    }
}

/// A new key is checked before saving. Existing keys are never read into the
/// field, and a failed replacement leaves the saved credential untouched.
@MainActor
struct ProviderKeyForm: View {
    @ObservedObject var viewModel: APIAndModelsViewModel
    let kind: AIProviderKind
    let account: ProviderAccount?
    var onBusyChanged: (Bool) -> Void = { _ in }
    let onClose: () -> Void

    @State private var key = ""
    @State private var name = ""
    @State private var baseURL = ""
    @State private var error: String?
    @State private var saving = false
    @State private var checking = false
    @State private var confirmingRemoval = false
    @FocusState private var keyFocused: Bool

    private var chip: KeyChip? { viewModel.chips.first { $0.account == account } }
    private var newServer: Bool { kind == .openAICompatible && account == nil }
    private var busy: Bool { saving || checking }
    private var canSave: Bool {
        !busy && (newServer ? !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  : !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chip?.title ?? kind.displayName)
                .font(.system(size: 13, weight: .semibold))
            if let chip {
                Text(chip.statusText).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
            }
            if newServer {
                MacField(placeholder: "Name", text: $name)
                MacField(placeholder: "Base URL", text: $baseURL, monospaced: true)
                Text("For example http://localhost:8000/v1")
                    .font(.caption).foregroundStyle(MacSettingsTheme.text2)
            }
            SecureField(chip == nil ? (newServer ? "API key (optional)" : "API key") : "New API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .focused($keyFocused)
                .onSubmit(save)
            Text("Checked with the provider before saving to your Mac Keychain.")
                .font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let account, chip != nil {
                    APIModelAction(title: "Check now", style: .default) {
                        checking = true
                        onBusyChanged(true)
                        Task {
                            await viewModel.checkKey(account)
                            checking = false
                            onBusyChanged(false)
                        }
                    }
                    APIModelAction(title: "Remove", style: .danger) { confirmingRemoval = true }
                }
                Spacer(minLength: 0)
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                }
                APIModelAction(title: "Cancel", style: .default, action: onClose)
                APIModelAction(title: "Check & save", style: .primary, isEnabled: canSave, action: save)
            }
            if confirmingRemoval, let account {
                let features = viewModel.featuresUsing(account)
                Text(features.isEmpty ? "No features use this key."
                     : "\(features.map(\.title).joined(separator: ", ")) will have no model.")
                    .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                HStack {
                    Spacer()
                    APIModelAction(title: "Keep key", style: .default) { confirmingRemoval = false }
                    APIModelAction(title: "Remove key", style: .danger) {
                        viewModel.remove(account)
                        onClose()
                    }
                }
            }
        }
        .foregroundStyle(MacSettingsTheme.text)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 12))
        .disabled(busy)
        .onAppear { keyFocused = true }
    }

    private func save() {
        guard canSave else { return }
        saving = true
        onBusyChanged(true)
        error = nil
        let candidate = key
        Task {
            let failure: String?
            if newServer {
                failure = await viewModel.addServer(name: name, baseURL: baseURL, key: candidate)
            } else if let account, chip != nil {
                failure = await viewModel.replaceKey(candidate, for: account)
            } else {
                failure = await viewModel.addKey(candidate, kind: kind)
            }
            saving = false
            onBusyChanged(false)
            if let failure { error = failure } else {
                key = ""
                if newServer { onClose() }
            }
        }
    }
}
