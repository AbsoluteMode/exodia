import Foundation

/// A calendar request never follows redirects with a bearer token or caches private responses.
final class CalendarHTTP: @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: CalendarNoRedirectDelegate(), delegateQueue: nil)
    }

    init(session: URLSession) { self.session = session }
    deinit { session.invalidateAndCancel() }

    func json(_ request: URLRequest) async throws -> [String: Any] {
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw CalendarConnectionError.invalidResponse }
            if response.statusCode == 401 { throw CalendarConnectionError.signInRequired }
            guard (200..<300).contains(response.statusCode) else { throw CalendarConnectionError.http(response.statusCode) }
            guard data.count <= 10_000_000,
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CalendarConnectionError.invalidResponse
            }
            return result
        } catch let error as CalendarConnectionError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw CalendarConnectionError.unavailable }
    }

    static func form(_ values: [String: String]) -> Data {
        // RFC 3986 escaping also escapes '+', '&' and '=' inside credential values.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" +
            $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").data(using: .utf8)!
    }

    static func apiURL(provider: CalendarProvider, path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = provider.apiHost
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, !provider.apiHost.isEmpty else { throw CalendarConnectionError.configuration }
        return url
    }

    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }
}

private final class CalendarNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
