import SwiftUI

/// The provider dropdown of an OpenRouter row: Auto, or one provider of the
/// selected model with its median latency and throughput over 30 minutes.
@MainActor
struct ProviderMenu: View {
    @ObservedObject var viewModel: APIAndModelsViewModel
    let feature: AIFeature
    let choice: ProviderChoice

    var body: some View {
        MacMenu(title: choice.label, maxWidth: 160) {
            Button {
                viewModel.selectProvider(nil, for: feature)
            } label: {
                itemLabel("Auto", selected: choice.pinned == nil)
            }
            Divider()
            switch viewModel.providerLists[choice.model] {
            case .loaded(let endpoints, _):
                ForEach(endpoints, id: \.tag) { endpoint in
                    Button {
                        viewModel.selectProvider(endpoint.tag, for: feature)
                    } label: {
                        itemLabel("\(endpoint.title)   \(endpoint.speedText)", selected: choice.pinned == endpoint.tag)
                    }
                }
                if let pinned = choice.pinned, !endpoints.contains(where: { $0.tag == pinned }) {
                    itemLabel("\(pinned)   not offered now", selected: true)
                }
            case .failed:
                Button("Couldn't load providers · Retry") {
                    Task { await viewModel.loadProviders(for: feature, force: true) }
                }
            case .loading, nil:
                Text("Loading providers…")
            }
        }
        .help("OpenRouter provider")
        .accessibilityLabel("Provider, \(choice.label)")
        .task(id: choice.model) { await viewModel.loadProviders(for: feature) }
    }

    @ViewBuilder
    private func itemLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
