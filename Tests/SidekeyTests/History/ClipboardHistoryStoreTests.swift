import XCTest
@testable import Sidekey

/// Tests for the clipboard-history extension on `SQLiteHistoryStore`.
/// Clipboard entries are richer than agent/drop rows — text, image, file
/// URLs — so they get their own table and their own enum payload.
final class ClipboardHistoryStoreTests: XCTestCase {
    private func makeStore() throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(path: ":memory:")
    }

    // MARK: - Text

    func testInsertTextEntryAssignsIdAndRoundtrips() throws {
        let store = try makeStore()
        let id = try store.insertClipboardTextEntry(
            createdAt: Date(timeIntervalSince1970: 1_000),
            text: "hello"
        )

        XCTAssertGreaterThan(id, 0)

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, id)
        XCTAssertEqual(entries.first?.createdAt, Date(timeIntervalSince1970: 1_000))
        guard case .text(let s) = entries.first?.payload else {
            XCTFail("expected .text, got \(String(describing: entries.first?.payload))")
            return
        }
        XCTAssertEqual(s, "hello")
    }

    func testLatestSortsNewestFirst() throws {
        let store = try makeStore()
        _ = try store.insertClipboardTextEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            text: "first"
        )
        _ = try store.insertClipboardTextEntry(
            createdAt: Date(timeIntervalSince1970: 3),
            text: "third"
        )
        _ = try store.insertClipboardTextEntry(
            createdAt: Date(timeIntervalSince1970: 2),
            text: "second"
        )

        let entries = try store.latestClipboardEntries(limit: 10)
        let texts = entries.compactMap { entry -> String? in
            if case .text(let s) = entry.payload { return s }
            return nil
        }
        XCTAssertEqual(texts, ["third", "second", "first"])
    }

    func testLatestRespectsLimit() throws {
        let store = try makeStore()
        for i in 0..<5 {
            _ = try store.insertClipboardTextEntry(
                createdAt: Date(timeIntervalSince1970: TimeInterval(i)),
                text: "t\(i)"
            )
        }
        let entries = try store.latestClipboardEntries(limit: 3)
        XCTAssertEqual(entries.count, 3)
    }

    // MARK: - File URLs

    func testInsertFileURLsEntryRoundtrips() throws {
        let store = try makeStore()
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.png")]
        let id = try store.insertClipboardFileURLsEntry(
            createdAt: Date(timeIntervalSince1970: 1_500),
            urls: urls
        )

        XCTAssertGreaterThan(id, 0)

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        guard case .fileURLs(let returned) = entries.first?.payload else {
            XCTFail("expected .fileURLs")
            return
        }
        XCTAssertEqual(returned, urls)
    }

    func testEmptyFileURLsIsRejected() {
        guard let store = try? makeStore() else {
            XCTFail("store init")
            return
        }
        XCTAssertThrowsError(
            try store.insertClipboardFileURLsEntry(
                createdAt: Date(),
                urls: []
            )
        )
    }

    // MARK: - Image

    func testInsertImageEntryWritesSidecarAndStoresThumbnail() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()
        let imageData = Data(repeating: 0xAB, count: 1024)
        let thumb = Data(repeating: 0xCD, count: 64)
        let id = try store.insertClipboardImageEntry(
            createdAt: Date(timeIntervalSince1970: 2_000),
            uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            imageData: imageData,
            imageExtension: "png",
            thumbnailData: thumb,
            assetsDirectory: assetsDir
        )
        XCTAssertGreaterThan(id, 0)

        let sidecar = assetsDir.appendingPathComponent("11111111-1111-1111-1111-111111111111.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let onDisk = try Data(contentsOf: sidecar)
        XCTAssertEqual(onDisk, imageData)

        let entries = try store.latestClipboardEntries(limit: 1)
        guard case .image(let imageEntry) = entries.first?.payload else {
            XCTFail("expected .image")
            return
        }
        XCTAssertEqual(imageEntry.uuid.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(imageEntry.fileExtension, "png")
        XCTAssertEqual(imageEntry.thumbnailData, thumb)
    }

    // MARK: - Cap eviction (FIFO + sidecar cleanup)

    func testEnforceCapEvictsOldestAndDeletesImageSidecars() throws {
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let store = try makeStore()

        // Insert 3 images with distinct timestamps.
        let oldestUUID = UUID()
        _ = try store.insertClipboardImageEntry(
            createdAt: Date(timeIntervalSince1970: 1),
            uuid: oldestUUID,
            imageData: Data([0x01]),
            imageExtension: "png",
            thumbnailData: Data([0xAA]),
            assetsDirectory: assetsDir
        )
        _ = try store.insertClipboardImageEntry(
            createdAt: Date(timeIntervalSince1970: 2),
            uuid: UUID(),
            imageData: Data([0x02]),
            imageExtension: "png",
            thumbnailData: Data([0xBB]),
            assetsDirectory: assetsDir
        )
        _ = try store.insertClipboardImageEntry(
            createdAt: Date(timeIntervalSince1970: 3),
            uuid: UUID(),
            imageData: Data([0x03]),
            imageExtension: "png",
            thumbnailData: Data([0xCC]),
            assetsDirectory: assetsDir
        )

        let oldestSidecar = assetsDir.appendingPathComponent("\(oldestUUID.uuidString).png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldestSidecar.path))

        // Cap at 2 — oldest must be evicted, sidecar deleted.
        try store.enforceClipboardCap(maxRows: 2, assetsDirectory: assetsDir)

        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 2)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldestSidecar.path),
            "oldest image sidecar should be deleted when entry is evicted"
        )
    }

    func testEnforceCapNoOpWhenUnderLimit() throws {
        let store = try makeStore()
        let assetsDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        _ = try store.insertClipboardTextEntry(createdAt: Date(timeIntervalSince1970: 1), text: "a")
        _ = try store.insertClipboardTextEntry(createdAt: Date(timeIntervalSince1970: 2), text: "b")
        try store.enforceClipboardCap(maxRows: 50, assetsDirectory: assetsDir)
        let entries = try store.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 2)
    }

    // MARK: - File-backed persistence

    /// Clipboard copies remain available after the app reopens its local DB.
    func testClipboardEntriesPersistAcrossReopen() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-clipboard-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            let store = try SQLiteHistoryStore(path: tmp.path)
            _ = try store.insertClipboardTextEntry(
                createdAt: Date(timeIntervalSince1970: 100),
                text: "persist me"
            )
        }

        let reopened = try SQLiteHistoryStore(path: tmp.path)
        let entries = try reopened.latestClipboardEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        guard case .text(let t) = entries.first?.payload else {
            XCTFail("expected text payload")
            return
        }
        XCTAssertEqual(t, "persist me")
    }

    func testImagesAndFileURLsRemainReadableAfterRepeatedReopens() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("history.sqlite")
        let assets = root.appendingPathComponent("assets")
        let imageID = UUID()
        let imageBytes = Data([0x01, 0x02, 0x03])
        let thumbnail = Data([0x04, 0x05])
        let fileURLs = [root.appendingPathComponent("example.txt")]
        let expected: [ClipboardHistoryEntry]
        do {
            let store = try SQLiteHistoryStore(path: database.path)
            _ = try store.insertClipboardImageEntry(
                createdAt: Date(timeIntervalSince1970: 1),
                uuid: imageID,
                imageData: imageBytes,
                imageExtension: "png",
                thumbnailData: thumbnail,
                assetsDirectory: assets
            )
            _ = try store.insertClipboardFileURLsEntry(
                createdAt: Date(timeIntervalSince1970: 2), urls: fileURLs
            )
            expected = try store.latestClipboardEntries(limit: 10)
        }

        for _ in 0..<3 {
            let reopened = try SQLiteHistoryStore(path: database.path)
            XCTAssertEqual(try reopened.latestClipboardEntries(limit: 10), expected)
            let feed = HistoryStripFeed(store: reopened)
            XCTAssertEqual(feed.cards(for: .clipboard).count, 2)
            XCTAssertEqual(
                try Data(contentsOf: assets.appendingPathComponent("\(imageID.uuidString).png")),
                imageBytes
            )
        }
    }

    @MainActor
    func testWatcherStopAndStartPreserveExistingCopies() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("history.sqlite")
        let assets = root.appendingPathComponent("assets")
        do {
            let store = try SQLiteHistoryStore(path: database.path)
            _ = try store.insertClipboardTextEntry(createdAt: Date(), text: "saved copy")
            let watcher = ClipboardWatcher(
                store: store, assetsDirectory: assets, suppression: ClipboardSuppression()
            )
            // Synchronous start/stop prevents the timer from polling the real
            // pasteboard. Only its change counter seeds watcher state.
            watcher.start()
            watcher.stop()
            watcher.start()
            watcher.stop()
            XCTAssertEqual(try store.latestClipboardEntries(limit: 10).count, 1)
        }

        let reopened = try SQLiteHistoryStore(path: database.path)
        let watcher = ClipboardWatcher(
            store: reopened, assetsDirectory: assets, suppression: ClipboardSuppression()
        )
        watcher.start()
        watcher.stop()
        XCTAssertEqual(try reopened.latestClipboardEntries(limit: 10).first?.payload, .text("saved copy"))
        XCTAssertEqual(HistoryStripFeed(store: reopened).cards(for: .clipboard).count, 1)
    }

    func testRetentionAfterReopenKeepsFiftyNewestAndCleansOnlyEvictedImage() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("history.sqlite")
        let assets = root.appendingPathComponent("assets")
        let oldestID = UUID()
        let retainedID = UUID()
        do {
            let store = try SQLiteHistoryStore(path: database.path)
            for (id, time) in [(oldestID, 0), (retainedID, 1)] {
                _ = try store.insertClipboardImageEntry(
                    createdAt: Date(timeIntervalSince1970: TimeInterval(time)), uuid: id,
                    imageData: Data([0x01]), imageExtension: "png", thumbnailData: Data([0x02]),
                    assetsDirectory: assets
                )
            }
            for time in 2..<50 {
                _ = try store.insertClipboardTextEntry(
                    createdAt: Date(timeIntervalSince1970: TimeInterval(time)), text: "copy \(time)"
                )
            }
        }

        do {
            let reopened = try SQLiteHistoryStore(path: database.path)
            XCTAssertEqual(try reopened.latestClipboardEntries(limit: 100).count, 50)
            _ = try reopened.insertClipboardTextEntry(
                createdAt: Date(timeIntervalSince1970: 50), text: "new copy after restart"
            )
            try reopened.enforceClipboardCap(maxRows: 50, assetsDirectory: assets)
        }

        let reopened = try SQLiteHistoryStore(path: database.path)
        let rows = try reopened.latestClipboardEntries(limit: 100)
        XCTAssertEqual(rows.count, 50)
        XCTAssertEqual(rows.first?.payload, .text("new copy after restart"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.appendingPathComponent("\(oldestID.uuidString).png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.appendingPathComponent("\(retainedID.uuidString).png").path))
    }

    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-clipboard-assets-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
