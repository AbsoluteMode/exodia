import Foundation

enum NativeAgentError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// No retries of a model/tool request: a retry could repeat a paid call or an action.
struct NativeAgentHTTP {
    var session: URLSession = .shared

    func json(_ request: URLRequest, limit: Int = 4_000_000) async throws -> [String: Any] {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeAgentError.message("The service returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            // Never echo provider response bodies: they can contain keys or request content.
            let message: String
            switch http.statusCode {
            case 401, 403: message = "The service refused this API key. Check Settings."
            case 402: message = "The provider has insufficient credit."
            case 429: message = "The service is busy or its usage limit was reached. Try again later."
            default: message = "The service returned HTTP \(http.statusCode). Try again."
            }
            throw NativeAgentError.message(message)
        }
        if response.expectedContentLength > limit { throw NativeAgentError.message("The service response is too large.") }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { throw NativeAgentError.message("The service response is too large.") }
            data.append(byte)
            if data.count % 4096 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeAgentError.message("The service returned invalid JSON.")
        }
        return object
    }

    static func request(url: URL, key: String, body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}
