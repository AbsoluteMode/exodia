import SQLite3
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

    /// Break caught: `update` writes `<id>.md` before it learns that the row
    /// is gone, so a note save that lands after Delete brings the note back.
    func test_update_of_a_deleted_meeting_writes_no_note_and_reports_it_missing() async throws {
        let store = try MeetingsStore(rootDirectory: root)
        let id = UUID()
        try await store.insert(meta: meta(id: id), markdown: "# Doomed\n\nBody.")
        try await store.delete(id: id)

        let updated = try await store.update(id: id, markdown: "# Doomed\n\nLate edit.", version: 2)

        XCTAssertFalse(updated, "there is no meeting left to update")
        let note = try await store.markdown(id: id)
        XCTAssertNil(note, "the note of a deleted meeting must not come back")
    }

    /// Break caught: the row goes although a file stays, or the note goes
    /// before the transcript. The user is then told the meeting is still in
    /// the list while it is gone, or it stays listed without its note.
    func test_delete_that_cannot_remove_the_transcript_keeps_the_meeting_and_its_note() async throws {
        let store = try MeetingsStore(rootDirectory: root)
        let id = UUID()
        let segments = [TranscriptSegment(speaker: "Speaker 1", start: 0, end: 2, text: "Hello")]
        try await store.insert(meta: meta(id: id), markdown: "# Kept\n\nBody.", transcript: segments)
        // The user-immutable flag makes the unlink fail while the directory,
        // and with it the database journal, stays writable.
        let transcriptPath = root.appendingPathComponent("\(id.uuidString)-transcript.json").path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: transcriptPath)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: transcriptPath) }

        var failed = false
        do { try await store.delete(id: id) } catch { failed = true }

        XCTAssertTrue(failed, "a delete that leaves a file behind must say so")
        let rows = try await store.list()
        XCTAssertEqual(rows.map(\.id), [id], "the meeting stays listed so Delete can be retried")
        let note = try await store.markdown(id: id)
        XCTAssertEqual(note, "# Kept\n\nBody.", "a listed meeting keeps its note")
    }

    /// Break caught: the files go before the row's own delete has succeeded,
    /// so a database failure leaves the meeting listed without its note.
    func test_delete_whose_row_cannot_be_deleted_keeps_the_note_and_the_transcript() async throws {
        let store = try MeetingsStore(rootDirectory: root)
        let id = UUID()
        let segments = [TranscriptSegment(speaker: "Speaker 1", start: 0, end: 2, text: "Hello")]
        try await store.insert(meta: meta(id: id), markdown: "# Kept\n\nBody.", transcript: segments)
        try refuseRowDeletes()

        var failed = false
        do { try await store.delete(id: id) } catch { failed = true }

        XCTAssertTrue(failed)
        let rows = try await store.list()
        XCTAssertEqual(rows.map(\.id), [id])
        let note = try await store.markdown(id: id)
        let transcript = try await store.transcript(id: id)
        XCTAssertEqual(note, "# Kept\n\nBody.")
        XCTAssertEqual(transcript?.count, 1)
    }

    /// Makes every row DELETE fail through a trigger installed over a second
    /// connection; the files stay removable.
    private func refuseRowDeletes() throws {
        var db: OpaquePointer?
        let path = root.appendingPathComponent("meetings.sqlite").path
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TRIGGER refuse_deletes BEFORE DELETE ON meetings
            BEGIN SELECT RAISE(ABORT, 'delete refused by the test'); END
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
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
