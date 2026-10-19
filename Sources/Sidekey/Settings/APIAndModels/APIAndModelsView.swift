import SwiftUI

/// The "API keys" and "Models" blocks of the API & Models tab. One model menu
/// per feature row: a provider is never picked on its own, only through the
/// model it serves.
@MainActor
struct APIAndModelsView: View {
    @ObservedObject var viewModel: APIAndModelsViewModel
    @Binding var focusedFeature: AIFeature?

    @State private var activeSheet: ActiveSheet?
    @State private var popoverAccount: ProviderAccount?
    @State private var highlighted: AIFeature?

    init(viewModel: APIAndModelsViewModel, focusedFeature: Binding<AIFeature?>) {
        self.viewModel = viewModel
        self._focusedFeature = focusedFeature
    }

    /// What the one sheet of the tab shows. The proposal wins: after Save the
    /// add-key window gives way to it without a second presentation.
    private enum ActiveSheet: Equatable {
        case addKey
        case otherModel(AIFeature)
    }

    private enum PresentedSheet: Identifiable {
        case addKey
        case otherModel(AIFeature)
        case assign(AssignProposal)

        var id: String {
            switch self {
            case .addKey: return "addKey"
            case .otherModel(let feature): return "otherModel.\(feature.rawValue)"
            case .assign: return "assign"
            }
        }
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    keysBlock
                    modelsBlock
                }
                .padding(.horizontal, 24).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: focusedFeature) { _, feature in
                if let feature { focus(feature, scroller: scroller) }
            }
            .task {
                if let feature = focusedFeature { focus(feature, scroller: scroller) }
                await viewModel.onAppear()
            }
        }
        .sheet(item: presentedSheet) { sheet in
            switch sheet {
            case .addKey:
                AddKeySheet(viewModel: viewModel) { activeSheet = nil }
            case .otherModel(let feature):
                OtherModelSheet(
                    feature: feature,
                    accounts: viewModel.sections(for: feature).map { ($0.account, $0.title) }
                ) { account, model in
                    activeSheet = nil
                    Task { await viewModel.select(model: model, account: account, for: feature) }
                } onCancel: { activeSheet = nil }
            case .assign(let proposal):
                AssignModelsSheet(
                    proposal: proposal,
                    onUse: { viewModel.applyProposal(selected: $0) },
                    onNotNow: { viewModel.proposal = nil }
                )
            }
        }
    }

    private var presentedSheet: Binding<PresentedSheet?> {
        Binding(
            get: {
                if let proposal = viewModel.proposal { return .assign(proposal) }
                switch activeSheet {
                case .addKey: return .addKey
                case .otherModel(let feature): return .otherModel(feature)
                case nil: return nil
                }
            },
            set: { newValue in
                guard newValue == nil else { return }
                activeSheet = nil
                viewModel.proposal = nil
            }
        )
    }

    // MARK: - API keys

    private var keysBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "API keys")
            ChipFlowLayout(spacing: 8) {
                ForEach(viewModel.chips) { chip in
                    chipButton(chip)
                }
                addKeyChip
            }
        }
    }

    private func chipButton(_ chip: KeyChip) -> some View {
        Button { popoverAccount = chip.account } label: {
            HStack(spacing: 6) {
                ProviderKindIcon(kind: chip.account.kind, size: 14)
                Text(chip.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text)
            }
            .chipBackground()
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(
            get: { popoverAccount == chip.account },
            set: { if !$0, popoverAccount == chip.account { popoverAccount = nil } }
        ), arrowEdge: .bottom) {
            KeyChipPopover(viewModel: viewModel, account: chip.account) { popoverAccount = nil }
        }
        .accessibilityLabel("\(chip.title), \(chip.statusText)")
    }

    private var addKeyChip: some View {
        Button { activeSheet = .addKey } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
                Text("Add key").font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(MacSettingsTheme.accent)
            .chipBackground()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Models

    private var modelsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Models")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(viewModel.aliasGroups.enumerated()), id: \.offset) { _, group in
                    aliasBanner(group)
                }
                if let banner = viewModel.unsetBanner {
                    bannerButton(text: "\(banner) · Set up", systemImage: "sparkles") {
                        viewModel.proposeSetup(for: nil)
                    }
                }
            }
            .padding(.bottom, viewModel.aliasGroups.isEmpty && viewModel.unsetBanner == nil ? 0 : 10)
            MacCard {
                ForEach(Array(viewModel.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { MacRowSeparator() }
                    featureRow(row)
                }
            }
        }
    }

    private func aliasBanner(_ group: AliasGroupAction) -> some View {
        let count = group.features.count
        return bannerButton(
            text: "Switch \(count) \(count == 1 ? "feature" : "features") to \(group.to)",
            systemImage: "arrow.triangle.2.circlepath"
        ) {
            Task { await viewModel.apply(group) }
        }
    }

    private func bannerButton(text: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MacBanner(tone: .warn, systemImage: systemImage, text: text)
        }
        .buttonStyle(.plain)
    }

    private func featureRow(_ row: FeatureRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MacRow(title: row.feature.title) {
                HStack(spacing: 10) {
                    if row.isChecking { ProgressView().controlSize(.small) }
                    Text(row.feature.mode.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .frame(minWidth: 70, alignment: .trailing)
                    ModelMenu(
                        viewModel: viewModel,
                        feature: row.feature,
                        label: row.selectionLabel,
                        onAddKey: { activeSheet = .addKey },
                        onOtherModel: { activeSheet = .otherModel(row.feature) }
                    )
                    if let choice = row.provider {
                        ProviderMenu(viewModel: viewModel, feature: row.feature, choice: choice)
                    }
                }
            }
            statusLines(for: row)
        }
        .background(highlighted == row.feature ? MacSettingsTheme.accent.opacity(0.16) : Color.clear)
        .animation(.easeInOut(duration: 0.25), value: highlighted)
        .id(row.feature)
    }

    @ViewBuilder
    private func statusLines(for row: FeatureRow) -> some View {
        let status = statusLine(for: row)
        if status != nil || row.message != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let status {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10.5))
                        Text(status.text)
                        if let action = status.action {
                            Button(action.title, action: action.run)
                                .buttonStyle(.plain)
                                .foregroundStyle(MacSettingsTheme.accent)
                        }
                    }
                }
                if let message = row.message {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10.5))
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(MacSettingsTheme.orange)
            .padding(.horizontal, 14)
            .padding(.top, -3)
            .padding(.bottom, 9)
        }
    }

    private struct StatusLine {
        struct Action {
            let title: String
            let run: () -> Void
        }
        let text: String
        var action: Action?
    }

    /// The row's problem as text with its one action; `nil` when it is fine.
    private func statusLine(for row: FeatureRow) -> StatusLine? {
        switch row.status {
        case .ok:
            return nil
        case .notSet:
            return StatusLine(text: "Not set")
        case .keyProblem:
            return StatusLine(text: "Key problem")
        case .notVerified:
            return StatusLine(text: "Not verified ·", action: .init(title: "Check now") {
                Task { await viewModel.checkNow(row.feature) }
            })
        case .removedByProvider:
            return StatusLine(text: "Removed by provider ·", action: .init(title: "Choose model") {
                chooseModel(for: row.feature)
            })
        case .deprecatedAlias(let target):
            let group = viewModel.aliasGroups.first { $0.features.contains(row.feature) }
            return StatusLine(
                text: "Alias of \(target)",
                action: group.map { group in
                    .init(title: "Switch to \(target)") { Task { await viewModel.apply(group) } }
                }
            )
        case .expiring(let date):
            return StatusLine(text: "Expires \(date.formatted(date: .abbreviated, time: .omitted))")
        case .notSupported(let reason):
            return StatusLine(text: "Not supported yet: \(reason) ·", action: .init(title: "Check now") {
                Task { await viewModel.checkNow(row.feature) }
            })
        }
    }

    /// The menu cannot be opened from code: the window below takes a model ID
    /// from a provider with a key; with none, it asks for a key first.
    private func chooseModel(for feature: AIFeature) {
        activeSheet = viewModel.sections(for: feature).isEmpty ? .addKey : .otherModel(feature)
    }

    // MARK: - Focus

    /// Scrolls to the row, lights it for a second and gives the binding back.
    private func focus(_ feature: AIFeature, scroller: ScrollViewProxy) {
        withAnimation { scroller.scrollTo(feature, anchor: .center) }
        highlighted = feature
        focusedFeature = nil
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if highlighted == feature { highlighted = nil }
        }
    }
}

/// The one place a provider kind becomes a brand mark. A kind without a brand
/// asset (Anthropic, a user's server) shows an SF Symbol.
@MainActor
struct ProviderKindIcon: View {
    let kind: AIProviderKind
    var size: CGFloat = 16

    var body: some View {
        if let assetName = Self.assetName(for: kind) {
            ProviderBrandIcon(assetName: assetName, size: size)
        } else {
            ProviderBrandIcon(systemName: Self.systemName(for: kind), size: size)
        }
    }

    static func systemName(for kind: AIProviderKind) -> String {
        switch kind {
        case .anthropic: return TranscriptionProviderBrand.anthropicSystemName
        case .soniox, .deepgram, .elevenLabs, .openRouter, .openAICompatible: return "server.rack"
        }
    }

    static func assetName(for kind: AIProviderKind) -> String? {
        switch kind {
        case .soniox: return "soniox"
        case .deepgram: return "deepgram"
        case .elevenLabs: return "elevenlabs"
        case .openRouter: return "openrouter"
        case .anthropic, .openAICompatible: return nil
        }
    }
}

private extension View {
    func chipBackground() -> some View {
        self
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(MacSettingsTheme.controlBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Chips left to right, wrapping to the next line when the width runs out.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(in: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, arranged.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (origins, CGSize(width: usedWidth, height: y + lineHeight))
    }
}
