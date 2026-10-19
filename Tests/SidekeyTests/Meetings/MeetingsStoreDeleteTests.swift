import XCTest
@testable import Sidekey

/// `MeetingsStore.delete(id:)` is what the user means by Delete: the meeting
/// leaves the list AND its note and transcript leave the disk.
final class MeetingsStoreDeleteTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-delete-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    /// Break caught: only the database row is deleted, so the note and the
    /// transcript of a "deleted" meeting stay readable on disk.
    func test_delete_removes_the_row_the_note_and_the_transcript_from_disk() async throws {
        let store = try MeetingsStore(rootDirectory: root)
        let doomed = UUID()
        let survivor = UUID()
        let segments = [TranscriptSegment(speaker: "Speaker 1", start: 0, end: 2, text: "Hello")]
        try await store.insert(meta: meta(id: doomed), markdown: "# Doomed\n\nBody.", transcript: segments)
        try await store.insert(meta: meta(id: survivor), markdown: "# Survivor\n\nBody.", transcript: segments)

        try await store.delete(id: doomed)

        let rows = try await store.list()
        XCTAssertEqual(rows.map(\.id), [survivor])
        let doomedNote = try await store.markdown(id: doomed)
        let doomedTranscript = try await store.transcript(id: doomed)
        XCTAssertNil(doomedNote)
        XCTAssertNil(doomedTranscript)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(doomed.uuidString) }
        XCTAssertEqual(leftovers, [], "no file of the deleted meeting may remain")
        let survivorNote = try await store.markdown(id: survivor)
        let survivorTranscript = try await store.transcript(id: survivor)
        XCTAssertNotNil(survivorNote, "another meeting's note is untouched")
        XCTAssertEqual(survivorTranscript?.count, 1, "another meeting's transcript is untouched")
    }

    /// Break caught: a missing sidecar turns Delete into an error, so a failed
    /// meeting (it never had a note) could not be deleted at all.
    func test_delete_succeeds_for_a_row_without_sidecars_and_can_be_repeated() async throws {
        let store = try MeetingsStore(rootDirectory: root)
        let id = UUID()
        try await store.upsertProgress(
            meta: meta(id: id),
            status: .failed,
            failureReason: "Processing failed"
        )

        try await store.delete(id: id)
        try await store.delete(id: id)

        let rows = try await store.list()
        XCTAssertTrue(rows.isEmpty)
    }

    private func meta(id: UUID) -> MeetingMetaWithLocalState {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        return MeetingMetaWithLocalState(
            id: id,
            startedAt: started,
            endedAt: started.addingTimeInterval(120),
            durationSeconds: 120,
            title: "Meeting",
            syncStatus: .new,
            serverVersion: 1,
            createdAt: started.addingTimeInterval(121)
        )
    }
}
