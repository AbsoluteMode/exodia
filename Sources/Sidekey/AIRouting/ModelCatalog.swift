import Foundation

/// One model as a provider's catalog describes it. Fields a provider does not
/// report stay `nil`.
struct CatalogModel: Codable, Equatable, Sendable {
    let id: String
    /// `nil`: the provider does not say (a user's server).
    var uses: Set<ModelUse>?
    /// Soniox `aliased_model_id`: the model this one is a deprecated alias of.
    var aliasOf: String?
    var contextLength: Int?
    /// OpenRouter `top_provider.max_completion_tokens`.
    var maxOutputTokens: Int?
    var supportsTools: Bool?
    /// `"reasoning"` is among OpenRouter's `supported_parameters`.
    var supportsReasoning: Bool?
    var reasoning: OpenRouterReasoningCapabilities?
    var expiresAt: Date?

    init(
        id: String,
        uses: Set<ModelUse>? = nil,
        aliasOf: String? = nil,
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsTools: Bool? = nil,
        supportsReasoning: Bool? = nil,
        reasoning: OpenRouterReasoningCapabilities? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.uses = uses
        self.aliasOf = aliasOf
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.supportsReasoning = supportsReasoning
        self.reasoning = reasoning
        self.expiresAt = expiresAt
    }
}

/// Why a catalog could not be read. Never carries a response body or a URL.
enum CatalogFetchError: Error, Equatable {
    /// Non-2xx. `code` is the provider's own error label when the body has one.
    case http(Int, code: String?)
    case offline
    case malformed
}

protocol ModelCatalogFetching: Sendable {
    /// `apiKey` is the caller's to read from the Keychain; `server` is required
    /// for a `.server` account. A server that answers 404 throws
    /// `.http(404, code: nil)`: the caller treats that as "no catalog".
    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel]
}

extension ServerEndpoint {
    /// Where this server lists its models: `ws`/`wss` become `http`/`https`; a
    /// base ending in `/v1` gets `/models`, anything else gets `/v1/models` on
    /// the same host and port. `nil` for a base that is not a web URL.
    var modelsURL: URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), components.host?.isEmpty == false
        else { return nil }
        switch scheme {
        case "http", "https": components.scheme = scheme
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        default: return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path.hasSuffix("/v1") ? path + "/models" : "/v1/models"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct ModelCatalogFetcher: ModelCatalogFetching {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private static let sonioxURL = URL(string: "https://api.soniox.com/v1/models")!
    private static let deepgramURL = URL(string: "https://api.deepgram.com/v1/models")!
    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/models")!

    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
        switch account {
        case .soniox:
            let data = try await get(Self.sonioxURL, bearer: apiKey)
            return try Self.parseSoniox(data)
        case .deepgram:
            // The Deepgram catalog is public; the key is not sent.
            let data = try await get(Self.deepgramURL, bearer: nil)
            return try Self.parseDeepgram(data)
        case .elevenLabs:
            // /v1/models lists voice models only; STT models come from the registry.
            return []
        case .openRouter:
            let data = try await get(Self.openRouterURL, bearer: nil)
            return try Self.parseOpenRouter(data)
        case .server:
            guard let url = server?.modelsURL else { throw CatalogFetchError.malformed }
            let data = try await get(url, bearer: apiKey)
            return try Self.parseServer(data)
        }
    }

    // MARK: - Transport

    private func get(_ url: URL, bearer: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is URLError {
            throw CatalogFetchError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw CatalogFetchError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            throw CatalogFetchError.http(http.statusCode, code: Self.errorCode(in: data))
        }
        return data
    }

    /// The provider's own label for an error, when the body has one:
    /// `error_type` (Soniox), `err_code` / `category` (Deepgram),
    /// `detail.status` (ElevenLabs).
    private static func errorCode(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        func text(_ value: Any?) -> String? {
            if let string = value as? String, !string.isEmpty { return string }
            return nil
        }
        if let code = text(object["error_type"]) ?? text(object["err_code"]) ?? text(object["category"]) {
            return code
        }
        return text((object["detail"] as? [String: Any])?["status"])
    }

    // MARK: - Parsing

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CatalogFetchError.malformed
        }
    }

    private struct SonioxResponse: Decodable {
        struct Model: Decodable {
            let id: String
            let transcriptionMode: String?
            let aliasedModelID: String?

            enum CodingKeys: String, CodingKey {
                case id
                case transcriptionMode = "transcription_mode"
                case aliasedModelID = "aliased_model_id"
            }
        }
        let models: [Model]
    }

    static func parseSoniox(_ data: Data) throws -> [CatalogModel] {
        try decode(SonioxResponse.self, from: data).models.map { model in
            let uses: Set<ModelUse>
            switch model.transcriptionMode {
            case "real_time": uses = [.realtimeSTT]
            case "async": uses = [.asyncSTT]
            default: uses = []
            }
            let alias = model.aliasedModelID.flatMap { $0.isEmpty ? nil : $0 }
            return CatalogModel(id: model.id, uses: uses, aliasOf: alias)
        }
    }

    private struct DeepgramResponse: Decodable {
        struct Row: Decodable {
            let canonicalName: String?
            let streaming: Bool?
            let batch: Bool?

            enum CodingKeys: String, CodingKey {
                case canonicalName = "canonical_name"
                case streaming
                case batch
            }
        }
        let stt: [Row]
    }

    static func parseDeepgram(_ data: Data) throws -> [CatalogModel] {
        // Rows are split by language and version; one model is the union of its rows.
        var usesByID: [String: Set<ModelUse>] = [:]
        for row in try decode(DeepgramResponse.self, from: data).stt {
            guard let id = row.canonicalName, !id.isEmpty else { continue }
            var uses = usesByID[id] ?? []
            if row.streaming == true { uses.insert(.realtimeSTT) }
            if row.batch == true { uses.insert(.asyncSTT) }
            usesByID[id] = uses
        }
        // `nova-3-general` is what the API calls plain `nova-3`.
        let generalSuffix = "-general"
        for (id, uses) in usesByID where id.hasSuffix(generalSuffix) && id.count > generalSuffix.count {
            let architecture = String(id.dropLast(generalSuffix.count))
            usesByID[architecture] = (usesByID[architecture] ?? []).union(uses)
        }
        return usesByID
            .filter { !$0.value.isEmpty }
            .map { CatalogModel(id: $0.key, uses: $0.value) }
            .sorted { $0.id < $1.id }
    }

    private struct OpenRouterResponse: Decodable {
        struct Model: Decodable {
            struct Architecture: Decodable {
                let outputModalities: [String]?
                enum CodingKeys: String, CodingKey { case outputModalities = "output_modalities" }
            }
            struct Pricing: Decodable { let prompt: String? }
            struct TopProvider: Decodable {
                let maxCompletionTokens: Int?
                enum CodingKeys: String, CodingKey { case maxCompletionTokens = "max_completion_tokens" }
            }

            let id: String
            let contextLength: Int?
            let expirationDate: String?
            let supportedParameters: [String]?
            let architecture: Architecture?
            let pricing: Pricing?
            let topProvider: TopProvider?
            let reasoning: OpenRouterReasoningCapabilities?

            enum CodingKeys: String, CodingKey {
                case id
                case contextLength = "context_length"
                case expirationDate = "expiration_date"
                case supportedParameters = "supported_parameters"
                case architecture
                case pricing
                case topProvider = "top_provider"
                case reasoning
            }
        }
        let data: [Model]
    }

    static func parseOpenRouter(_ data: Data) throws -> [CatalogModel] {
        try decode(OpenRouterResponse.self, from: data).data.compactMap { model in
            let id = model.id
            // `:batch` variants and `~…-latest` aliases are not models to pick.
            if id.contains(":batch") || id.contains("~") { return nil }
            // Text must be an output (a missing list is read as text, as the LLM client does).
            if let outputs = model.architecture?.outputModalities, !outputs.contains("text") { return nil }
            // Routers priced at -1 are not models, except the one the app has always offered.
            if model.pricing?.prompt == "-1", id != "openrouter/auto" { return nil }
            let parameters = model.supportedParameters
            let tools = parameters?.contains("tools")
            var uses: Set<ModelUse> = [.chat]
            if tools == true { uses.insert(.chatWithTools) }
            return CatalogModel(
                id: id,
                uses: uses,
                contextLength: model.contextLength,
                maxOutputTokens: model.topProvider?.maxCompletionTokens,
                supportsTools: tools,
                supportsReasoning: parameters?.contains("reasoning"),
                reasoning: model.reasoning,
                expiresAt: model.expirationDate.flatMap(parseDate)
            )
        }
    }

    private struct ServerResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    static func parseServer(_ data: Data) throws -> [CatalogModel] {
        try decode(ServerResponse.self, from: data).data.map { CatalogModel(id: $0.id) }
    }

    private static func parseDate(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: text)
    }
}
