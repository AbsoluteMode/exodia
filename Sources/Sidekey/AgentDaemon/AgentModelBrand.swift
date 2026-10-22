import Foundation

/// The model's author, not the OpenRouter host selected to serve it.
// WHY: .project-docs/decisions/2026-10-22-native-agent.md
enum AgentModelBrand: String, CaseIterable, Sendable {
    case openai, anthropic, google, deepseek, qwen, mistral, cohere, perplexity

    var label: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Gemini"
        case .deepseek: return "DeepSeek"
        case .qwen: return "Qwen"
        case .mistral: return "Mistral"
        case .cohere: return "Cohere"
        case .perplexity: return "Perplexity"
        }
    }

    var assetName: String { "model-\(rawValue)" }
    var iconURL: URL {
        let file: String
        switch self {
        case .openai: file = "OpenAI.svg"
        case .anthropic: file = "Anthropic.svg"
        case .google: file = "GoogleGemini.svg"
        case .deepseek: file = "DeepSeek.png"
        case .qwen: file = "Qwen.png"
        case .mistral: file = "Mistral.png"
        case .cohere: file = "Cohere.png"
        case .perplexity: file = "Perplexity.svg"
        }
        return URL(string: "https://openrouter.ai/images/icons/\(file)")!
    }

    static func resolve(_ route: FeatureRoute) -> AgentModelBrand? {
        switch route.account {
        case .openAI: return .openai
        case .anthropic: return .anthropic
        case .openRouter:
            let model = OpenCodeEnvironment.normalizeModel(route.model).lowercased()
            guard let author = model.split(separator: "/").first, model.contains("/") else { return nil }
            switch author {
            case "openai": return .openai
            case "anthropic": return .anthropic
            case "google", "google-vertex": return .google
            case "deepseek": return .deepseek
            case "qwen", "qwen2", "qwen3": return .qwen
            case "mistralai": return .mistral
            case "cohere": return .cohere
            case "perplexity": return .perplexity
            default: return nil
            }
        default: return nil
        }
    }
}
