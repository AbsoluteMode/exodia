import Foundation

enum SonioxUsagePriceError: Error { case unavailable, invalidResponse, limitReached }

/// Read only provider billing metadata. Exact references, never dates or account
/// totals, attribute a charge to a feature. Missing/delayed logs retain estimates.
/// API contract: https://soniox.com/docs/openapi.yaml (/v1/usage-logs).
actor SonioxUsagePrices {
    static let shared = SonioxUsagePrices()
    private let session: URLSession
    private let readKey: () -> String?
    init(session: URLSession = .shared, readKey: @escaping () -> String? = {
        if case .key(let key) = ProviderKeyStore().lookup(account: BYOKKeyStore.account(for: .soniox)) { return key }
        return nil
    }) { self.session = session; self.readKey = readKey }

    struct Entry: Equatable {
        let id: String
        let reference: String
        let model: String
        let amount: Double
    }
    struct Page { let entries: [Entry]; let cursor: String? }

    static func reference(_ event: AIUsageEvent) -> (value: String, isJob: Bool)? {
        guard event.context.account == .soniox, event.currency == .usd, event.basis != .reported else { return nil }
        for (prefix, isJob) in [("soniox:", false), ("soniox-job:", true)] where event.id.hasPrefix(prefix) {
            let value = String(event.id.dropFirst(prefix.count))
            if !value.isEmpty, value.count <= 256 { return (value, isJob) }
        }
        return nil
    }

    func prices(for events: [AIUsageEvent], now: Date = Date()) async throws -> [AIUsageEvent] {
        let pending = events.filter { Self.reference($0) != nil }
        guard !pending.isEmpty else { return [] }
        guard let key = readKey(), !key.isEmpty else { throw SonioxUsagePriceError.unavailable }
        // Retention is 91 days. Leave a small margin for client/server clock
        // differences; an old unresolved row must not reject fresh prices.
        let start = max(pending.map(\.createdAt).min()!.addingTimeInterval(-60), now.addingTimeInterval(-91 * 86400 + 60))
        // Usage logs filter by request END time. Include audio and async completion
        // beyond the selected day's end without changing the feature's date.
        let end = now
        guard start < end else { return [] }
        var entries: [String: Entry] = [:], conflicting = Set<String>()
        var windowStart = start, requests = 0
        let formatter = ISO8601DateFormatter()
        while windowStart < end {
            let windowEnd = min(end, windowStart.addingTimeInterval(31 * 86400))
            var cursor: String?, seenCursors = Set<String>()
            repeat {
                try Task.checkCancellation()
                guard requests < 40 else { throw SonioxUsagePriceError.limitReached }
                requests += 1
                var url = URLComponents(string: "https://api.soniox.com/v1/usage-logs")!
                url.queryItems = [URLQueryItem(name: "start_time", value: formatter.string(from: windowStart)),
                                 URLQueryItem(name: "end_time", value: formatter.string(from: windowEnd)),
                                 URLQueryItem(name: "limit", value: "1000"),
                                 URLQueryItem(name: "sort", value: "end_time_asc")]
                if let cursor { url.queryItems!.append(URLQueryItem(name: "cursor", value: cursor)) }
                var request = URLRequest(url: url.url!); request.timeoutInterval = 12
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SonioxUsagePriceError.unavailable }
                let page = try Self.parse(data)
                for entry in page.entries {
                    if let old = entries[entry.id], old != entry { conflicting.insert(entry.id) }
                    entries[entry.id] = entry
                }
                cursor = page.cursor
                if let cursor, !seenCursors.insert(cursor).inserted { throw SonioxUsagePriceError.invalidResponse }
            } while cursor != nil
            windowStart = windowEnd
        }
        return Self.match(pending, entries: entries.values.filter { !conflicting.contains($0.id) })
    }

    static func parse(_ data: Data) throws -> Page {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["usage_logs"] as? [[String: Any]] else { throw SonioxUsagePriceError.invalidResponse }
        var entries: [Entry] = []
        for row in rows {
            guard row["request_scope"] as? String == "api",
                  let id = row["uuid"] as? String, !id.isEmpty, id.count <= 256,
                  let reference = row["client_reference_id"] as? String, reference.count <= 256,
                  let model = row["model"] as? String, !model.isEmpty,
                  let amount = AIUsageNumber.decimal(row["cost_usd"]) else { continue }
            entries.append(Entry(id: id, reference: reference, model: model, amount: amount))
        }
        let cursor: String?
        if let value = object["next_page_cursor"], !(value is NSNull) {
            guard let value = value as? String, !value.isEmpty, value.count <= 4096 else { throw SonioxUsagePriceError.invalidResponse }
            cursor = value
        } else { cursor = nil }
        return Page(entries: entries, cursor: cursor)
    }

    static func match(_ events: [AIUsageEvent], entries: [Entry]) -> [AIUsageEvent] {
        events.compactMap { event in
            guard let reference = reference(event) else { return nil }
            let matches = entries.filter {
                $0.model == event.context.model && (reference.isJob ? $0.id == reference.value : $0.reference == reference.value)
            }
            guard matches.count == 1 else { return nil }
            return AIUsageEvent(id: event.id, createdAt: event.createdAt, context: event.context, currency: .usd,
                                amount: matches[0].amount, basis: .reported, audioSeconds: event.audioSeconds)
        }
    }
}
