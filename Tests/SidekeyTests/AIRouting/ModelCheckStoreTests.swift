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
}
