import XCTest
@testable import Sidekey

final class HistoryStripFeedTests: XCTestCase {
    private func makeStore() throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(path: ":memory:")
    }

    // MARK: - Agent

    func testAgentFeedReturnsCompletedTurns() throws {
        let store = try makeStore()
        let id = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            queryText: "hello",
            queryMode: .text,
            responseMarkdown: "Visit https://example.com for more.",
            toolNames: []
        )
        try store.updateAgentEntry(
            id: id,
            title: "Greeting",
            blocksJSON: nil,
            status: .done,
            responseMarkdown: "Visit https://example.com for more.",
            toolNames: []
        )

        let feed = HistoryStripFeed(store: store)
        let cards = feed.cards(for: .agent)
        XCTAssertEqual(cards.count, 1)
        guard case .agent(let agent) = cards.first else {
            XCTFail("expected agent card")
            return
        }
        XCTAssertEqual(agent.title, "Greeting")
        XCTAssertEqual(agent.links, [URL(string: "https://example.com")!])
    }

    func testAgentFeedExcludesPendingAndStreamingTurns() throws {
        let store = try makeStore()
        let pendingId = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            queryText: "p",
            queryMode: .text,
            responseMarkdown: "",
            toolNames: []
        )
        try store.updateAgentEntry(
            id: pendingId,
            title: nil,
            blocksJSON: nil,
            status: .pending,
            responseMarkdown: "",
            toolNames: []
        )

        let doneId = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 2),
            queryText: "d",
            queryMode: .text,
            responseMarkdown: "ok",
            toolNames: []
        )
        try store.updateAgentEntry(
            id: doneId,
            title: nil,
            blocksJSON: nil,
            status: .done,
            responseMarkdown: "ok",
            toolNames: []
        )

        let feed = HistoryStripFeed(store: store)
        let cards = feed.cards(for: .agent)
        XCTAssertEqual(cards.count, 1)
    }

    func testAgentFeedIncludesErrorTurns() throws {
        let store = try makeStore()
        let id = try store.insertAgentEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            queryText: "q",
            queryMode: .text,
            responseMarkdown: "Failed.",
            toolNames: []
        )
        try store.updateAgentEntry(
            id: id,
            title: nil,
            blocksJSON: nil,
            status: .error,
            responseMarkdown: "Failed.",
            toolNames: []
        )

        let feed = HistoryStripFeed(store: store)
        XCTAssertEqual(feed.cards(for: .agent).count, 1)
    }

    // MARK: - Drop

    func testDropFeedReturnsAllEntries() throws {
        let store = try makeStore()
        _ = try store.insertDropEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            rawTranscript: "raw",
            formattedText: "Formatted.",
            targetApp: "Notes"
        )

        let feed = HistoryStripFeed(store: store)
        let cards = feed.cards(for: .drop)
        XCTAssertEqual(cards.count, 1)
        guard case .drop(let drop) = cards.first else {
            XCTFail("expected drop")
            return
        }
        XCTAssertEqual(drop.formattedText, "Formatted.")
        XCTAssertEqual(drop.targetApp, "Notes")
    }

    // MARK: - Clipboard

    func testClipboardFeedReturnsTextEntries() throws {
        let store = try makeStore()
        _ = try store.insertClipboardTextEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            text: "copied"
        )

        let feed = HistoryStripFeed(store: store)
        let cards = feed.cards(for: .clipboard)
        XCTAssertEqual(cards.count, 1)
        guard
            case .clipboard(let clip) = cards.first,
            case .text(let s) = clip.payload
        else {
            XCTFail("expected clipboard.text")
            return
        }
        XCTAssertEqual(s, "copied")
    }

    func testEmptyFeedReturnsEmptyArray() throws {
        let store = try makeStore()
        let feed = HistoryStripFeed(store: store)
        XCTAssertEqual(feed.cards(for: .agent), [])
        XCTAssertEqual(feed.cards(for: .drop), [])
        XCTAssertEqual(feed.cards(for: .clipboard), [])
    }

    // MARK: - Per-mode feed limits

    /// Clipboard exposes twenty copies without deleting older stored rows.
    func testClipboardFeedCapsAtTwentyNewestWithoutDeletingOlderEntries() throws {
        let store = try makeStore()
        for i in 1...25 {
            _ = try store.insertClipboardTextEntry(
                createdAt: Date(timeIntervalSince1970: TimeInterval(i)),
                text: "entry-\(i)"
            )
        }

        let feed = HistoryStripFeed(store: store)
        let cards = feed.cards(for: .clipboard)
        XCTAssertEqual(cards.count, 20, "clipboard must expose the latest 20 entries")

        // Newest first: cards[0] should be the most recent (ts 25).
        guard
            case .clipboard(let newest) = cards.first,
            case .text(let s) = newest.payload
        else {
            XCTFail("expected first card to be newest clipboard text")
            return
        }
        XCTAssertEqual(s, "entry-25")

        // The twentieth card is ts 6. Rows 1...5 remain in storage.
        guard
            case .clipboard(let oldestInWindow) = cards.last,
            case .text(let lastStr) = oldestInWindow.payload
        else {
            XCTFail("expected last card to be oldest within the 20-window")
            return
        }
        XCTAssertEqual(lastStr, "entry-6")
        XCTAssertEqual(try store.latestClipboardEntries(limit: 100).count, 25)
    }

    func testDropFeedCapsAtTenNewest() throws {
        let store = try makeStore()
        for i in 1...15 {
            _ = try store.insertDropEntry(
                createdAt: Date(timeIntervalSince1970: TimeInterval(i)),
                rawTranscript: "raw-\(i)",
                formattedText: "drop-\(i)",
                targetApp: nil
            )
        }

        let feed = HistoryStripFeed(store: store)
        let cards = feed.cards(for: .drop)
        XCTAssertEqual(cards.count, 10)
        guard case .drop(let newest) = cards.first else {
            XCTFail("expected drop card")
            return
        }
        XCTAssertEqual(newest.formattedText, "drop-15")
    }

    func testAgentFeedCapsAtTenNewest() throws {
        let store = try makeStore()
        for i in 1...15 {
            let id = try store.insertAgentEntry(
                createdAt: Date(timeIntervalSince1970: TimeInterval(i)),
                queryText: "q-\(i)",
                queryMode: .text,
                responseMarkdown: "ans-\(i)",
                toolNames: []
            )
            try store.updateAgentEntry(
                id: id,
                title: "T\(i)",
                blocksJSON: nil,
                status: .done,
                responseMarkdown: "ans-\(i)",
                toolNames: []
            )
        }

        let feed = HistoryStripFeed(store: store)
        let cards = feed.cards(for: .agent)
        XCTAssertEqual(cards.count, 10)
        guard case .agent(let newest) = cards.first else {
            XCTFail("expected agent card")
            return
        }
        XCTAssertEqual(newest.title, "T15")
    }
}
