import Foundation
import CoreFoundation

enum AIUsageNumber {
    static func decimal(_ value: Any?) -> Double? {
        if let string = value as? String, let number = Double(string), number.isFinite, number >= 0 { return number }
        return nonnegative(value)
    }
    static func nonnegative(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
}

struct ElevenLabsBillingRow: Identifiable, Sendable {
    let id: String
    let keyName: String
    let model: String
    let product: String
    let credits: Double
    let minutes: Double?
}

struct ElevenLabsBillingUsage: Sendable {
    let rows: [ElevenLabsBillingRow]
    var credits: Double { rows.reduce(0) { $0 + $1.credits } }

    /// Apply this model's reported credits/minute only to our recorded time.
    /// The account total is not distributed among features or converted from USD.
    func estimating(_ event: AIUsageEvent) -> AIUsageEvent {
        guard event.context.account == .elevenLabs, event.amount == nil, event.audioSeconds > 0 else { return event }
        let matching = rows.filter { $0.product == "STT" && $0.model == event.context.model && ($0.minutes ?? 0) > 0 }
        let minutes = matching.reduce(0) { $0 + ($1.minutes ?? 0) }
        let credits = matching.reduce(0) { $0 + $1.credits }
        guard minutes.isFinite, credits.isFinite, minutes > 0, credits > 0 else { return event }
        let amount = event.audioSeconds / 60 * credits / minutes
        guard amount.isFinite else { return event }
        return AIUsageEvent(id: event.id, createdAt: event.createdAt, context: event.context,
                            currency: event.currency, amount: amount, basis: .estimated, audioSeconds: event.audioSeconds)
    }
}

enum ElevenLabsBillingError: Error {
    case keyUnavailable, http(Int), invalidResponse
    var message: String {
        switch self {
        case .keyUnavailable: return "Unlock the ElevenLabs API key and try again."
        case .http(401): return "ElevenLabs rejected the API key. Check it in API keys."
        case .http(403): return "This ElevenLabs key needs permission to read usage."
        case .http(429): return "ElevenLabs is limiting usage checks. Try again shortly."
        case .http: return "ElevenLabs couldn’t load usage. Try again."
        case .invalidResponse: return "ElevenLabs returned usage without usable credit amounts."
        }
    }
}

/// The live request log does not contain billing amounts. Read the credit/minute
/// usage table instead; preserve its key/model grouping and explicit scope.
/// WHY: .project-docs/decisions/2026-10-20-feature-costs.md
actor ElevenLabsCreditUsage {
    static let shared = ElevenLabsCreditUsage()
    private let session: URLSession
    private let readKey: () throws -> String?
    private let cacheURL: URL
    private var cache: RateCache?
    private var cacheLoaded = false
    private struct RateCache: Codable {
        let updatedAt: Date
        let rates: [String: Double]
    }

    init(session: URLSession = .shared,
         cacheURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(BuildConfig.bundleID).appendingPathComponent("elevenlabs-credit-rates.json"),
         readKey: @escaping () throws -> String? = {
        switch ProviderKeyStore().lookup(account: BYOKKeyStore.account(for: .elevenLabs)) {
        case .key(let key): return key
        case .absent: return nil
        case .unreadable: throw ElevenLabsBillingError.keyUnavailable
        }
    }) {
        self.session = session; self.cacheURL = cacheURL; self.readKey = readKey
    }

    /// Rate metadata only: no account totals, key names or provider identifiers.
    /// Once learned, local estimates survive API outages and period changes.
    func estimates(for events: [AIUsageEvent], now: Date = Date(), refresh: Bool = true) async -> [AIUsageEvent] {
        if !cacheLoaded {
            cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(RateCache.self, from: $0) }
            cacheLoaded = true
        }
        let models = Set(events.filter { $0.context.account == .elevenLabs && $0.audioSeconds > 0 }.map { $0.context.model })
        guard !models.isEmpty else { return events }
        if refresh, cache == nil || now.timeIntervalSince(cache!.updatedAt) > 86400 || models.contains(where: { cache?.rates[$0] == nil }) {
            let interval = DateInterval(start: now.addingTimeInterval(-31 * 86400), end: now)
            if let usage = try? await usage(in: interval) {
                var rates = cache?.rates ?? [:]
                for model in models {
                    let rows = usage.rows.filter { $0.product == "STT" && $0.model == model && ($0.minutes ?? 0) > 0 }
                    let minutes = rows.reduce(0) { $0 + ($1.minutes ?? 0) }
                    let rate = rows.reduce(0) { $0 + $1.credits } / minutes
                    if rate.isFinite, rate > 0 { rates[model] = rate }
                }
                cache = RateCache(updatedAt: now, rates: rates)
                if let data = try? JSONEncoder().encode(cache!) {
                    try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: cacheURL, options: .atomic)
                }
            }
        }
        return events.map { event in
            guard event.context.account == .elevenLabs, event.currency == .elevenLabsCredits,
                  event.amount == nil, event.audioSeconds > 0,
                  let rate = cache?.rates[event.context.model], rate.isFinite, rate > 0 else { return event }
            let amount = event.audioSeconds / 60 * rate
            guard amount.isFinite else { return event }
            return AIUsageEvent(id: event.id, createdAt: event.createdAt, context: event.context,
                                currency: event.currency, amount: amount, basis: .estimated, audioSeconds: event.audioSeconds)
        }
    }

    func usage(in interval: DateInterval) async throws -> ElevenLabsBillingUsage? {
        guard let key = try readKey(), !key.isEmpty else { return nil }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/workspace/analytics/query/usage-by-product-over-time")!)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "start_time": Int(interval.start.timeIntervalSince1970 * 1000),
            "end_time": Int(interval.end.timeIntervalSince1970 * 1000),
            "interval_seconds": 86400,
            "time_zone": TimeZone.current.identifier,
            "group_by": ["hashed_xi_api_key", "model", "product_type"]
        ])
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ElevenLabsBillingError.invalidResponse }
        guard response.statusCode == 200 else { throw ElevenLabsBillingError.http(response.statusCode) }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> ElevenLabsBillingUsage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let columns = object["columns"] as? [String], Set(columns).count == columns.count,
              let units = object["column_units"] as? [Any], units.count == columns.count,
              let rows = object["rows"] as? [[Any]],
              let creditIndex = columns.firstIndex(of: "total_usage"), units[creditIndex] as? String == "credits",
              units.filter({ $0 as? String == "credits" }).count == 1,
              let modelIndex = columns.firstIndex(of: "model"),
              let productIndex = columns.firstIndex(of: "product_type"),
              let keyIndex = columns.firstIndex(of: "hashed_xi_api_key") else { throw ElevenLabsBillingError.invalidResponse }
        let nameIndex = columns.firstIndex(of: "api_key_name")
        let minuteIndex = columns.firstIndex(of: "total_minutes").flatMap { units[$0] as? String == "min" ? $0 : nil }
        func number(_ value: Any) -> Double? {
            if let string = value as? String, let number = Double(string), number.isFinite, number >= 0 { return number }
            return AIUsageNumber.nonnegative(value)
        }
        var grouped: [String: ElevenLabsBillingRow] = [:]
        for row in rows {
            guard row.count == columns.count, let credits = number(row[creditIndex]),
                  let product = row[productIndex] as? String else {
                throw ElevenLabsBillingError.invalidResponse
            }
            let model = row[modelIndex] as? String ?? "Unspecified model"
            // Provider hashes are transient grouping IDs, never logs or journal data.
            let key = row[keyIndex] as? String ?? "unassigned"
            let id = key + "|" + product + "|" + model
            let name = nameIndex.flatMap { row[$0] as? String }.flatMap { $0.isEmpty ? nil : $0 } ?? "Other key"
            let minutes = minuteIndex.flatMap { number(row[$0]) }
            if let old = grouped[id] {
                let sum = old.credits + credits
                guard sum.isFinite else { throw ElevenLabsBillingError.invalidResponse }
                grouped[id] = .init(id: id, keyName: name, model: model, product: product, credits: sum,
                                    minutes: old.minutes.flatMap { previous in minutes.map { previous + $0 } })
            } else {
                grouped[id] = .init(id: id, keyName: name, model: model, product: product, credits: credits, minutes: minutes)
            }
        }
        let result = ElevenLabsBillingUsage(rows: grouped.values.sorted { ($0.keyName, $0.model, $0.id) < ($1.keyName, $1.model, $1.id) })
        guard result.credits.isFinite else { throw ElevenLabsBillingError.invalidResponse }
        return result
    }
}
