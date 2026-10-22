import AppKit
import Foundation

/// Optional public artwork refresh, completely outside recording/model startup.
/// Bundled marks are always available; failures leave the last usable mark.
@MainActor
final class AgentModelIconStore {
    static let shared = AgentModelIconStore()
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60
    static let retryInterval: TimeInterval = 6 * 60 * 60
    static let maximumBytes = 256 * 1024

    private struct CachedIcon: Codable, Sendable {
        let data: Data
        let etag: String?
        let checkedAt: Date
    }
    private let session: URLSession
    private let directory: URL?
    private let now: () -> Date
    private var images: [AgentModelBrand: NSImage] = [:]
    private var entries: [AgentModelBrand: CachedIcon] = [:]
    private var retryAfter: [AgentModelBrand: Date] = [:]
    private var inflight: [AgentModelBrand: Task<NSImage?, Never>] = [:]

    init(session: URLSession? = nil, directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 4
            config.timeoutIntervalForResource = 4
            self.session = URLSession(configuration: config)
        }
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("whytap/model-icons", isDirectory: true)
        self.now = now
    }

    func image(for brand: AgentModelBrand) async -> NSImage? {
        if let task = inflight[brand] { return await task.value }
        let task = Task { await self.load(brand) }
        inflight[brand] = task
        let result = await task.value
        inflight[brand] = nil
        return result
    }

    private func load(_ brand: AgentModelBrand) async -> NSImage? {
        let file = directory?.appendingPathComponent("\(brand.rawValue).json")
        if entries[brand] == nil, let file {
            let maximumBytes = Self.maximumBytes
            let cached = await Task.detached(priority: .utility) { () -> CachedIcon? in
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= maximumBytes * 2, let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(CachedIcon.self, from: data)
            }.value
            if let cached, let image = Self.decode(cached.data, brand: brand) { entries[brand] = cached; images[brand] = image }
        }
        let date = now()
        if let checked = entries[brand]?.checkedAt, date.timeIntervalSince(checked) < Self.refreshInterval { return images[brand] }
        if let retry = retryAfter[brand], date < retry { return images[brand] }
        var request = URLRequest(url: brand.iconURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue("Whytap", forHTTPHeaderField: "User-Agent")
        request.setValue("image/svg+xml,image/png", forHTTPHeaderField: "Accept")
        if let etag = entries[brand]?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, http) = try await Self.download(request, session: session, limit: Self.maximumBytes)
            let entry: CachedIcon
            if http.statusCode == 304, let existing = entries[brand] {
                entry = CachedIcon(data: existing.data, etag: existing.etag, checkedAt: date)
            } else {
                guard http.statusCode == 200, data.count <= Self.maximumBytes,
                      let image = Self.decode(data, brand: brand) else { throw URLError(.cannotDecodeContentData) }
                entry = CachedIcon(data: data, etag: http.value(forHTTPHeaderField: "ETag"), checkedAt: date)
                images[brand] = image
            }
            entries[brand] = entry
            retryAfter[brand] = nil
            if let file {
                await Task.detached(priority: .utility) {
                    guard let data = try? JSONEncoder().encode(entry) else { return }
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: file, options: .atomic)
                }.value
            }
        } catch {
            retryAfter[brand] = date.addingTimeInterval(Self.retryInterval)
        }
        return images[brand]
    }

    private nonisolated static func download(_ request: URLRequest, session: URLSession,
                                            limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              [200, 304].contains(http.statusCode), response.expectedContentLength <= limit else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return (data, http)
    }

    private static func decode(_ data: Data, brand: AgentModelBrand) -> NSImage? {
        guard data.count <= maximumBytes else { return nil }
        var artwork = data
        // This source is a monogram on an opaque rounded tile. The voice mark
        // needs the monogram's alpha, otherwise template tint produces a square.
        if brand == .anthropic, let source = String(data: data, encoding: .utf8), source.contains("<svg") {
            guard source.contains("<rect fill=\"#CC9B7A\""), source.contains("viewBox=\"0 0 512 512\"") else { return nil }
            let mark = source.replacingOccurrences(of: #"<rect\b[^>]*/>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "viewBox=\"0 0 512 512\"", with: "viewBox=\"100 130 310 250\"")
                .replacingOccurrences(of: "width=\"512\" height=\"512\"", with: "width=\"310\" height=\"250\"")
            artwork = Data(mark.utf8)
        }
        if brand == .perplexity, let source = String(data: data, encoding: .utf8), source.contains("<svg") {
            let mark = source.replacingOccurrences(of: #"stroke-width\s*=\s*(?:"[^"]*"|'[^']*')"#,
                with: "", options: .regularExpression)
                .replacingOccurrences(of: "<svg", with: "<svg stroke-width=\"3\"")
            artwork = Data(mark.utf8)
        }
        guard let image = NSImage(data: artwork),
              image.size.width > 0, image.size.height > 0,
              image.size.width <= 2048, image.size.height <= 2048 else { return nil }
        return image
    }
}
