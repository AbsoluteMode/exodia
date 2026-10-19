import Foundation

/// One provider endpoint OpenRouter can serve a model through, with its speed
/// over the last 30 minutes. OpenRouter reports latency and throughput only to
/// a request that carries a key; without them both are `nil`.
struct OpenRouterEndpoint: Equatable, Sendable {
    /// What `provider.order` takes, e.g. `"deepinfra/fp4"`.
    let tag: String
    let providerName: String
    let quantization: String?
    /// Time to first token, median, in milliseconds.
    let latencyMs: Double?
    /// Output tokens per second, median.
    let tokensPerSecond: Double?
    /// OpenRouter's status is 0 for a working endpoint.
    let isUp: Bool

    /// `"DeepInfra · fp4"`; the quantization only when OpenRouter names one.
    var title: String {
        guard let quantization, !quantization.isEmpty, quantization != "unknown" else { return providerName }
        return "\(providerName) · \(quantization)"
    }

    /// `"0.42 s · 85 tok/s"`, with a dash for a figure OpenRouter did not report.
    var speedText: String {
        let latency = latencyMs.map { String(format: "%.2f s", $0 / 1000) } ?? "— s"
        let throughput = tokensPerSecond.map { "\(Int($0.rounded())) tok/s" } ?? "— tok/s"
        return "\(latency) · \(throughput)"
    }
}

protocol OpenRouterEndpointsFetching: Sendable {
    func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint]
}

/// `GET /models/{model}/endpoints`: a free metadata request; no prompt, audio
/// or text is sent.
struct OpenRouterEndpointsClient: OpenRouterEndpointsFetching {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] {
        guard let url = Self.url(base: baseURL, model: model) else { throw OpenRouterLLMError.missingModel }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OpenRouterLLMError.unexpectedStatus(http.statusCode, nil)
        }
        return try Self.decode(data)
    }

    /// The model ID keeps its slashes: `…/models/deepseek/deepseek-chat-v3.1/endpoints`.
    static func url(base: URL, model: String) -> URL? {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains(where: \.isWhitespace), !id.contains("..") else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        guard let path = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        return URL(string: "\(root)/models/\(path)/endpoints")
    }

    static func decode(_ data: Data) throws -> [OpenRouterEndpoint] {
        struct Percentiles: Decodable { let p50: Double? }
        struct Endpoint: Decodable {
            let provider_name: String
            let tag: String?
            let quantization: String?
            let status: Int?
            let latency_last_30m: Percentiles?
            let throughput_last_30m: Percentiles?
        }
        struct Envelope: Decodable {
            struct Payload: Decodable { let endpoints: [Endpoint] }
            let data: Payload
        }
        return try JSONDecoder().decode(Envelope.self, from: data).data.endpoints.map {
            OpenRouterEndpoint(
                tag: $0.tag ?? $0.provider_name.lowercased(),
                providerName: $0.provider_name,
                quantization: $0.quantization,
                latencyMs: $0.latency_last_30m?.p50,
                tokensPerSecond: $0.throughput_last_30m?.p50,
                isUp: ($0.status ?? 0) == 0
            )
        }
    }

    /// Fastest first: most tokens per second, then lowest latency; endpoints
    /// without figures and those that are down go last.
    static func sorted(_ endpoints: [OpenRouterEndpoint]) -> [OpenRouterEndpoint] {
        endpoints.sorted { a, b in
            if a.isUp != b.isUp { return a.isUp }
            switch (a.tokensPerSecond, b.tokensPerSecond) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            switch (a.latencyMs, b.latencyMs) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.title < b.title
            }
        }
    }
}
