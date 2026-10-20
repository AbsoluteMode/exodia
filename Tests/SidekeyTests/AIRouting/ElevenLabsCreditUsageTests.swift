import XCTest
@testable import Sidekey

final class ElevenLabsCreditUsageTests: XCTestCase {
    private func response(rows: [[Any]], columns: [String] = ["request_id", "model_id", "cost"],
                          units: [Any] = [NSNull(), NSNull(), "credits"]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["columns": columns, "column_units": units, "rows": rows])
    }

    func test_exact_request_and_model_match_with_provider_credit_unit() throws {
        let data = try response(rows: [["other-app", "scribe", 900], ["ours", "scribe", 12.5]])
        XCTAssertEqual(ElevenLabsCreditUsage.credits(in: data, reference: "ours", model: "scribe"), 12.5)
        XCTAssertNil(ElevenLabsCreditUsage.credits(in: data, reference: "our", model: "scribe"))
        XCTAssertNil(ElevenLabsCreditUsage.credits(in: data, reference: "ours", model: "another-model"))
        let free = try response(rows: [["ours", "scribe", 0]])
        XCTAssertEqual(ElevenLabsCreditUsage.credits(in: free, reference: "ours", model: "scribe"), 0)
    }

    func test_no_usd_conversion_or_ambiguous_component_summing() throws {
        let usd = try response(rows: [["ours", "scribe", 0.1]], units: [NSNull(), NSNull(), "usd"])
        XCTAssertNil(ElevenLabsCreditUsage.credits(in: usd, reference: "ours", model: "scribe"))
        let ambiguous = try response(rows: [["ours", "scribe", 10, 20]],
            columns: ["request_id", "model_id", "cost", "another_cost"], units: [NSNull(), NSNull(), "credits", "credits"])
        XCTAssertNil(ElevenLabsCreditUsage.credits(in: ambiguous, reference: "ours", model: "scribe"))
        let duplicate = try response(rows: [["ours", "scribe", 1], ["ours", "scribe", 2]])
        XCTAssertNil(ElevenLabsCreditUsage.credits(in: duplicate, reference: "ours", model: "scribe"))
        let boolean = try response(rows: [["ours", "scribe", true]])
        XCTAssertNil(ElevenLabsCreditUsage.credits(in: boolean, reference: "ours", model: "scribe"))
    }

    func test_analytics_reconciles_one_event_without_duplicate_or_changed_attribution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("credits-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIUsageStore(url: directory.appendingPathComponent("usage.sqlite"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        let now = Date()
        let event = AIUsageEvent(id: "elevenlabs:ours", createdAt: now,
            context: .init(feature: .dropFast, account: .elevenLabs, model: "scribe"),
            currency: .elevenLabsCredits, amount: nil, basis: .unavailable, audioSeconds: 10)
        try await store.insert(event)
        let data = try response(rows: [["ours", "scribe", 123]])
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/workspace/analytics/requests")
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "fixture-key")
            return (200, [:], data)
        }
        let client = ElevenLabsCreditUsage(session: session, readKey: { "fixture-key" })
        await client.refresh(events: [event], store: store, now: now)
        // Repeated unknown records and another feature with the same ID cannot
        // erase a known debit or assign that debit to a different feature.
        try await store.insert(event)
        try await store.insert(.init(id: event.id, createdAt: now,
            context: .init(feature: .agentVoice, account: .elevenLabs, model: "scribe"),
            currency: .elevenLabsCredits, amount: 999, basis: .reported))
        let rows = try await store.events(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.amount, 123)
        XCTAssertEqual(rows.first?.basis, .reported); XCTAssertEqual(rows.first?.context.feature, .dropFast)
        XCTAssertEqual(try XCTUnwrap(rows.first).createdAt.timeIntervalSince1970, event.createdAt.timeIntervalSince1970, accuracy: 0.00001)
    }

    func test_analytics_permission_error_keeps_credits_unknown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("credits-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIUsageStore(url: directory.appendingPathComponent("usage.sqlite"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        let now = Date(), event = AIUsageEvent(id: "elevenlabs:ours",
            context: .init(feature: .dropFast, account: .elevenLabs, model: "scribe"),
            currency: .elevenLabsCredits, amount: nil, basis: .unavailable)
        try await store.insert(event)
        StubURLProtocol.handler = { _ in (403, [:], Data()) }
        await ElevenLabsCreditUsage(session: session, readKey: { "fixture" }).refresh(events: [event], store: store)
        let rows = try await store.events(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(60))
        XCTAssertEqual(rows.count, 1); XCTAssertNil(rows.first?.amount)
    }
}
