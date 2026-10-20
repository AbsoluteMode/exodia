import XCTest
@testable import Sidekey

final class MeetingContinuationTests: XCTestCase {
    private var root: URL!
    private let start = Date(timeIntervalSince1970: 1_000)
    private let firstNote = "<!-- protocol:v1 -->\n# Planning\n\nFirst call.\n\n## Tasks\n- First task\n\n## Decisions\n- None\n\n## Other\n- Keep this"
    private let secondNote = "<!-- protocol:v1 -->\n# Continuation\n\nSecond call.\n\n## Tasks\n- Second task\n\n## Decisions\n- Ship\n\n## Other\n- None"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func seed(_ store: MeetingsStore, id: UUID) async throws -> UUID {
        try await store.storeProcessedRecording(recordingId: id, startedAt: start,
            endedAt: start.addingTimeInterval(42), duration: 42, title: "Planning",
            markdown: firstNote,
            transcript: [.init(speaker: "Speaker 1", start: 0, end: 42, text: "First")], continuation: nil)
    }

    private func append(_ store: MeetingsStore, parent: UUID, recording: UUID) async throws {
        let continuation = MeetingContinuation(meetingId: parent, precedingRecordingId: parent,
            startedAt: start, audioOffsetSeconds: 42, gapSeconds: 120)
        try await store.beginContinuationUpdate(id: parent)
        _ = try await store.storeProcessedRecording(recordingId: recording,
            startedAt: start.addingTimeInterval(162), endedAt: start.addingTimeInterval(172),
            duration: 10, title: "Continuation", markdown: secondNote,
            transcript: [.init(speaker: "Speaker 1", start: 0, end: 10, text: "Second")],
            continuation: continuation)
    }

    func testContinuationUpdatesOneMeetingAndKeepsBothTranscriptParts() async throws {
        let store = try MeetingsStore(rootDirectory: root)
        let id = UUID(), recording = UUID()
        try await seed(store, id: id)
        try await append(store, parent: id, recording: recording)
        let rows = try await store.list()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, id)
        XCTAssertEqual(rows.first?.title, "Planning")
        XCTAssertEqual(rows.first?.durationSeconds, 52)
        XCTAssertEqual(rows.first?.startedAt, start)
        XCTAssertEqual(rows.first?.endedAt, start.addingTimeInterval(172))
        XCTAssertEqual(rows.first?.progressStatus, .ready)
        let savedMarkdown = try await store.markdown(id: id)
        let markdown = try XCTUnwrap(savedMarkdown)
        let note = try XCTUnwrap(MeetingProtocolParser.parse(markdown))
        XCTAssertEqual(note.name, "Planning")
        XCTAssertEqual(note.tasks.map(\.task), ["First task", "Second task"])
        XCTAssertEqual(note.decisions.map(\.text), ["Ship"])
        let transcript = try await store.transcript(id: id)
        XCTAssertEqual(transcript?.map(\.text), ["First", "Reconnected after 2m 0s", "Second"])
        XCTAssertEqual(transcript?.last?.start, 42)
        XCTAssertEqual(transcript?.last?.end, 52)
        XCTAssertNotEqual(transcript?.first?.speaker, transcript?.last?.speaker)
        await store.close()
    }

    func testReplayingCommittedContinuationAfterReopenDoesNotAppendAgain() async throws {
        let id = UUID(), recording = UUID()
        let first = try MeetingsStore(rootDirectory: root)
        try await seed(first, id: id)
        try await append(first, parent: id, recording: recording)
        let before = try await first.markdown(id: id)
        await first.close()
        let reopened = try MeetingsStore(rootDirectory: root)
        try await append(reopened, parent: id, recording: recording)
        let after = try await reopened.markdown(id: id)
        let transcript = try await reopened.transcript(id: id)
        XCTAssertEqual(before, after)
        XCTAssertEqual(transcript?.count, 3)
        await reopened.close()
    }

    func testCommittedSnapshotSurvivesFailureBetweenSidecarWrites() async throws {
        let store = try MeetingsStore(rootDirectory: root)
        let blockedId = UUID()
        // Transcript materialization succeeds; the markdown destination fails.
        let blocked = root.appendingPathComponent(blockedId.uuidString + ".md")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data([1]).write(to: blocked.appendingPathComponent("block"))
        do { try await seed(store, id: blockedId); XCTFail("Expected a sidecar write error") }
        catch {}
        let saved = try await store.markdown(id: blockedId)
        let committed = try await store.hasProcessedRecording(blockedId)
        XCTAssertEqual(saved, firstNote)
        XCTAssertTrue(committed)
        await store.close()
        try FileManager.default.removeItem(at: blocked)
        let reopened = try MeetingsStore(rootDirectory: root)
        try await seed(reopened, id: blockedId)
        let persisted = try await reopened.transcript(id: blockedId)
        XCTAssertEqual(persisted?.count, 1)
        let rows = try await reopened.list()
        XCTAssertEqual(rows.filter { $0.id == blockedId }.count, 1)
        await reopened.close()
    }

    func testEditOpenedBeforeContinuationKeepsUserChangesAndNewFindings() async throws {
        let store = try MeetingsStore(rootDirectory: root)
        let id = UUID()
        try await seed(store, id: id)
        let edited = firstNote.replacingOccurrences(of: "First task", with: "My edited task")
        try await append(store, parent: id, recording: UUID())
        _ = try await store.update(id: id, markdown: edited, version: 2)
        let result = try await store.markdown(id: id)
        XCTAssertTrue(result?.contains("My edited task") == true)
        XCTAssertTrue(result?.contains("Second task") == true)
        let rows = try await store.list()
        XCTAssertEqual(rows.first?.serverVersion, 3)
        await store.close()
    }

    func testUpdatingStatusKeepsPreviousNoteReadableAndBlocksDelete() async throws {
        let store = try MeetingsStore(rootDirectory: root)
        let id = UUID()
        try await seed(store, id: id)
        try await store.beginContinuationUpdate(id: id)
        let status = try await store.progressStatus(id: id)
        let note = try await store.markdown(id: id)
        XCTAssertEqual(status, .updating)
        XCTAssertFalse(MeetingProgressStatus.updating.canBeDeleted)
        XCTAssertEqual(note, firstNote)
        await store.close()
    }

    func testMalformedProtocolAdditionRemainsVisibleInGenericRenderer() {
        let result = MeetingContinuationMarkdown.appending("# Later call\n\nNew information", to: firstNote)
        XCTAssertNil(MeetingProtocolParser.parse(result), "Structured rendering must not hide the extra section")
        XCTAssertTrue(result.contains("First task"))
        XCTAssertTrue(result.contains("New information"))
        XCTAssertTrue(result.contains("# Planning"))
    }

    func testSpeechAfterInitialSilenceReplacesOnlyTheUntouchedPlaceholder() async throws {
        let store = try MeetingsStore(rootDirectory: root)
        let id = UUID()
        _ = try await store.storeProcessedRecording(recordingId: id, startedAt: start,
            endedAt: start.addingTimeInterval(42), duration: 42, title: MeetingBYOKProcessor.noSpeechTitle,
            markdown: MeetingBYOKProcessor.noSpeechMarkdown, transcript: [], continuation: nil)
        try await append(store, parent: id, recording: UUID())
        let note = try await store.markdown(id: id)
        let rows = try await store.list()
        XCTAssertEqual(note, secondNote)
        XCTAssertEqual(rows.first?.title, "Continuation")
        await store.close()
    }

    func testDeleteClearsBothPhysicalRecordingReceipts() async throws {
        let store = try MeetingsStore(rootDirectory: root)
        let id = UUID(), recording = UUID()
        try await seed(store, id: id)
        try await append(store, parent: id, recording: recording)
        try await store.delete(id: id)
        let firstReceipt = try await store.hasProcessedRecording(id)
        let laterReceipt = try await store.hasProcessedRecording(recording)
        XCTAssertFalse(firstReceipt)
        XCTAssertFalse(laterReceipt)
        await store.close()
    }

    func testSilenceContinuationPreservesEarlierNote() async throws {
        let store = try MeetingsStore(rootDirectory: root)
        let id = UUID()
        try await seed(store, id: id)
        _ = try await store.storeProcessedRecording(recordingId: UUID(), startedAt: start,
            endedAt: start.addingTimeInterval(60), duration: 2,
            title: MeetingBYOKProcessor.noSpeechTitle, markdown: MeetingBYOKProcessor.noSpeechMarkdown,
            transcript: [], continuation: .init(meetingId: id, precedingRecordingId: id,
                startedAt: start, audioOffsetSeconds: 42, gapSeconds: 16))
        let result = try await store.markdown(id: id)
        XCTAssertEqual(result, firstNote)
        await store.close()
    }
}
