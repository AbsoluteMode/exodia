import Foundation
import CoreFoundation

enum AIUsageNumber {
    static func nonnegative(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
}

/// Provider-reported credits, joined by the exact request/session identifier
/// captured from this app's socket. Never allocate account-wide credit deltas
/// to a feature: other apps and simultaneous features can use the same key.
/// Contract: official elevenlabs-python workspace/analytics/requests client and
/// WorkspaceAnalyticsQueryResponseModel (columns, column_units, rows).
/// https://github.com/elevenlabs/elevenlabs-python/tree/main/src/elevenlabs/workspace/analytics/requests
actor ElevenLabsCreditUsage {
    static let shared = ElevenLabsCreditUsage()
    private let session: URLSession
    private let readKey: () -> String?
    private var attempted: [String: Date] = [:]
    private var inFlight = Set<String>()

    init(session: URLSession = .shared, readKey: @escaping () -> String? = {
        if case .key(let key) = ProviderKeyStore().lookup(account: BYOKKeyStore.account(for: .elevenLabs)) { return key }
        return nil
    }) {
        self.session = session; self.readKey = readKey
    }

    func refresh(events: [AIUsageEvent], store: AIUsageStore, now: Date = Date()) async {
        let pending = events.filter {
            $0.currency == .elevenLabsCredits && $0.amount == nil && $0.id.hasPrefix("elevenlabs:")
                && !inFlight.contains($0.id) && now.timeIntervalSince(attempted[$0.id] ?? .distantPast) >= 30
        }.prefix(20)
        guard !pending.isEmpty, let key = readKey(), !key.isEmpty else { return }
        // Only retain retry timestamps for recently inspected requests.
        attempted = attempted.filter { now.timeIntervalSince($0.value) < 3600 }
        for event in pending {
            if inFlight.contains(event.id) || now.timeIntervalSince(attempted[event.id] ?? .distantPast) < 30 { continue }
            attempted[event.id] = now; inFlight.insert(event.id)
            defer { inFlight.remove(event.id) }
            let reference = String(event.id.dropFirst("elevenlabs:".count))
            guard !reference.isEmpty, reference.count <= 256 else { continue }
            var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/workspace/analytics/requests")!)
            request.httpMethod = "POST"; request.timeoutInterval = 12
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "start_time": Int(event.createdAt.addingTimeInterval(-120).timeIntervalSince1970 * 1000),
                "end_time": Int(now.addingTimeInterval(60).timeIntervalSince1970 * 1000),
                "search": reference, "limit": 10
            ]
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let amount = Self.credits(in: data, reference: reference, model: event.context.model) else { continue }
                let reconciled = AIUsageEvent(id: event.id, createdAt: event.createdAt, context: event.context,
                    currency: .elevenLabsCredits, amount: amount, basis: .reported, audioSeconds: event.audioSeconds)
                await store.record(reconciled)
            } catch { /* Unavailable remains visible; normal inference is independent of billing reads. */ }
        }
    }

    static func credits(in data: Data, reference: String, model: String) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let columns = object["columns"] as? [String],
              let units = object["column_units"] as? [Any], units.count == columns.count,
              let rows = object["rows"] as? [[Any]] else { return nil }
        let creditColumns = units.indices.filter { units[$0] as? String == "credits" }
        // Ambiguous currencies/cost components must not silently become a total.
        guard creditColumns.count == 1, let creditIndex = creditColumns.first else { return nil }
        let idColumns = columns.indices.filter { ["request_id", "session_id", "id"].contains(columns[$0]) }
        guard !idColumns.isEmpty else { return nil }
        let modelIndex = columns.firstIndex(of: "model_id") ?? columns.firstIndex(of: "model")
        let matched = rows.filter { row in
            guard row.count == columns.count, idColumns.contains(where: { row[$0] as? String == reference }) else { return false }
            return modelIndex.map { row[$0] as? String == model } ?? true
        }
        guard matched.count == 1 else { return nil }
        return AIUsageNumber.nonnegative(matched[0][creditIndex])
    }
}
