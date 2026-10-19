import XCTest
@testable import Sidekey

@MainActor
final class ModelCheckStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ModelCheckStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private let key = ModelCheckKey(account: "openRouter", model: "vendor/model", use: .chat)

    func test_adapter_version_is_part_of_the_record() {
        let defaults = makeDefaults()
        let date = Date(timeIntervalSince1970: 3_000_000)
        let store = ModelCheckStore(defaults: defaults)
        XCTAssertNil(store.record(for: key))

        store.store(.passed, for: key, adapterVersion: 1, at: date)
        XCTAssertEqual(store.record(for: key), ModelCheckRecord(adapterVersion: 1, outcome: .passed, at: date))

        // A newer adapter checks again and replaces the record.
        store.store(.failed(reason: "Provider refused: nope"), for: key, adapterVersion: 2, at: date.addingTimeInterval(60))
        XCTAssertEqual(store.record(for: key)?.adapterVersion, 2)
        XCTAssertEqual(store.record(for: key)?.outcome, .failed(reason: "Provider refused: nope"))

        // The record is per account, model and use.
        XCTAssertNil(store.record(for: ModelCheckKey(account: "openRouter", model: "vendor/model", use: .chatWithTools)))
        XCTAssertNil(store.record(for: ModelCheckKey(account: "soniox", model: "vendor/model", use: .chat)))

        let reopened = ModelCheckStore(defaults: defaults)
        XCTAssertEqual(reopened.record(for: key)?.adapterVersion, 2)
    }

    func test_inconclusive_is_not_stored() {
        let store = ModelCheckStore(defaults: makeDefaults())
        store.store(.inconclusive(reason: "No connection"), for: key, adapterVersion: 1, at: Date())
        XCTAssertNil(store.record(for: key))
    }

    func test_refusal_is_kept_per_feature() {
        let defaults = makeDefaults()
        let store = ModelCheckStore(defaults: defaults)
        XCTAssertNil(store.refusedModel(for: .dropFast))

        store.recordRefusal(feature: .dropFast, model: "model-a", at: Date(timeIntervalSince1970: 10))
        store.recordRefusal(feature: .agent, model: "model-b", at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(store.refusedModel(for: .dropFast), "model-a")
        XCTAssertEqual(store.refusedModel(for: .agent), "model-b")
        XCTAssertNil(store.refusedModel(for: .meetings))

        let reopened = ModelCheckStore(defaults: defaults)
        XCTAssertEqual(reopened.refusedModel(for: .dropFast), "model-a")
        XCTAssertEqual(reopened.refusedModel(for: .agent), "model-b")
    }

    /// A refusal goes once that model works again (final review I2); a
    /// different model's success leaves it.
    func test_clear_refusal_only_for_the_refused_model() {
        let defaults = makeDefaults()
        let store = ModelCheckStore(defaults: defaults)
        store.recordRefusal(feature: .dropSmartCleanup, model: "model-a", at: Date())
        store.recordRefusal(feature: .meetingNotes, model: "model-a", at: Date())

        store.clearRefusal(feature: .dropSmartCleanup, model: "model-b")
        XCTAssertEqual(store.refusedModel(for: .dropSmartCleanup), "model-a")

        store.clearRefusal(feature: .dropSmartCleanup, model: "model-a")
        XCTAssertNil(store.refusedModel(for: .dropSmartCleanup))
        XCTAssertEqual(store.refusedModel(for: .meetingNotes), "model-a")
        XCTAssertNil(ModelCheckStore(defaults: defaults).refusedModel(for: .dropSmartCleanup))
    }

    /// A long input or the account's data policy is not the model being
    /// refused (final review I2).
    func test_context_overflow_and_data_policy_are_not_model_refusals() {
        XCTAssertTrue(OpenRouterLLMError.unexpectedStatus(400, nil).isModelRefusal)
        XCTAssertTrue(OpenRouterLLMError.unexpectedStatus(404, "vendor/gone is not a valid model ID").isModelRefusal)
        XCTAssertTrue(OpenRouterLLMError.unexpectedStatus(422, "Unprocessable").isModelRefusal)
        XCTAssertFalse(OpenRouterLLMError.unexpectedStatus(401, nil).isModelRefusal)
        XCTAssertFalse(OpenRouterLLMError.unexpectedStatus(
            400, "This endpoint's maximum context length is 8192 tokens. However, you requested about 9000 tokens."
        ).isModelRefusal)
        XCTAssertFalse(OpenRouterLLMError.unexpectedStatus(400, "context_length_exceeded").isModelRefusal)
        XCTAssertFalse(OpenRouterLLMError.unexpectedStatus(
            404, "No endpoints found matching your data policy (Free model publication)."
        ).isModelRefusal)
    }
}
