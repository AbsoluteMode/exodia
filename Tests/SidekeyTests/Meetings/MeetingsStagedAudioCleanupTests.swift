import XCTest
@testable import Sidekey

/// A staged recording must not outlive the meeting it belongs to.
///
/// Launch recovery finishes the cleanup an interrupted run left behind, and
/// deleting a meeting removes everything that would bring it back or keep its
/// content on disk. Real `MeetingsStore` and real files in a temp directory;
/// only the transcription processor is a spy.
@MainActor
final class MeetingsStagedAudioCleanupTests: XCTestCase {
    private var tempRoot: URL!
    private var testDefaults: UserDefaults!
    private var defaultsSuiteName: String!

    private var meetingsRoot: URL { tempRoot.appendingPathComponent("Meetings") }
    private var stagingRoot: URL { tempRoot.appendingPathComponent("meetings-staging") }

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "com.sidekey.meetings.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("staged-audio-cleanup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // One test makes the staging root read-only; never leave that behind.
        chmod(stagingRoot.path, 0o755)
        try? FileManager.default.removeItem(at: tempRoot)
        testDefaults.removePersistentDomain(forName: defaultsSuiteName)
        testDefaults = nil
        defaultsSuiteName = nil
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - Launch recovery

    /// Break caught: recovery drops only `manifest.json` of a stored meeting
    /// and leaves its audio and checkpoint on disk for good.
    func test_launch_recovery_removes_the_whole_staged_dir_when_the_meeting_already_has_a_note() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.insert(meta: meta(id: id, status: .ready), markdown: "# Done\n\nBody.")
        let dir = try stageRecording(id: id)
        let processor = SpyDirectProcessor()
        let coordinator = makeCoordinator(store: store, processor: processor)

        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.path),
            "audio of an already stored meeting is a leftover, not a backup"
        )
        XCTAssertTrue(processor.processedIds.isEmpty, "a stored meeting is never processed again")
        let note = try await store.markdown(id: id)
        XCTAssertNotNil(note, "cleaning the staged audio must not touch the note")
    }

    /// Break caught: deleting the staged dir on `.ready` alone would destroy
    /// the only copy of the audio when the note itself is missing.
    func test_launch_recovery_keeps_the_audio_when_the_row_is_ready_but_its_note_is_missing() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(meta: meta(id: id, status: .ready), status: .ready)
        let dir = try stageRecording(id: id)
        let processor = SpyDirectProcessor()
        let coordinator = makeCoordinator(store: store, processor: processor)

        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("chunk-000.wav").path),
            "without a note the staged audio is the only source left"
        )
        XCTAssertFalse(MeetingFinalizeManifestStore().manifestExists(in: dir), "the stale manifest still goes")
        XCTAssertTrue(processor.processedIds.isEmpty)
    }

    /// Break caught: cleaning more than the stored meeting's own directory,
    /// for example the staging root or a neighbour that is still unprocessed.
    func test_launch_recovery_leaves_the_dir_of_an_unprocessed_meeting_alone() async throws {
        let store = try makeStore()
        let storedId = UUID()
        try await store.insert(meta: meta(id: storedId, status: .ready), markdown: "# Done")
        let storedDir = try stageRecording(id: storedId)
        let pendingId = UUID()
        let pendingDir = try stageRecording(id: pendingId)
        let processor = SpyDirectProcessor()
        let coordinator = makeCoordinator(store: store, processor: processor)

        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertFalse(FileManager.default.fileExists(atPath: storedDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDir.appendingPathComponent("chunk-000.wav").path))
        XCTAssertEqual(processor.processedIds, [pendingId], "only the unprocessed meeting is processed")
    }

    // MARK: - Deleting a meeting

    /// Break caught: deleting only the database row leaves the note, the
    /// transcript and the audio of the meeting on disk.
    func test_delete_meeting_removes_row_note_transcript_and_staged_audio() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.insert(
            meta: meta(id: id, status: .ready),
            markdown: "# Planning\n\nBody.",
            transcript: [TranscriptSegment(speaker: "Speaker 1", start: 0, end: 2, text: "Hello")]
        )
        let dir = try stageRecording(id: id)
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor())

        let deleted = await coordinator.deleteMeeting(id: id)

        XCTAssertTrue(deleted)
        let rows = try await store.list()
        XCTAssertTrue(rows.isEmpty)
        let note = try await store.markdown(id: id)
        XCTAssertNil(note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(
            try fileNames(in: meetingsRoot, mentioning: id), [],
            "no note or transcript file may stay behind after Delete"
        )
    }

    /// Break caught: the manifest outlives the row, so the next launch
    /// recovery re-processes the recording and the deleted meeting returns.
    func test_deleted_failed_meeting_is_not_brought_back_by_launch_recovery() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(
            meta: meta(id: id, status: .failed),
            status: .failed,
            failureReason: "Soniox returned no speaker-attributed transcript."
        )
        _ = try stageRecording(id: id)
        let processor = SpyDirectProcessor()
        let coordinator = makeCoordinator(store: store, processor: processor)

        let deleted = await coordinator.deleteMeeting(id: id)
        await coordinator.recoverFinalizeManifestsOnLaunch()

        XCTAssertTrue(deleted)
        XCTAssertTrue(processor.processedIds.isEmpty, "a deleted meeting must not be processed again")
        let rows = try await store.list()
        XCTAssertTrue(rows.isEmpty, "recovery must not recreate the deleted row")
    }

    /// Break caught: deleting while a processor still works on the meeting;
    /// its final insert would silently bring the row back.
    func test_delete_meeting_is_refused_while_the_meeting_is_still_processing() async throws {
        let store = try makeStore()
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor())

        for status in [
            MeetingProgressStatus.waitingToReconnect, .uploading, .transcribing, .generatingProtocol,
        ] {
            let id = UUID()
            try await store.upsertProgress(meta: meta(id: id, status: status), status: status)
            let dir = try stageRecording(id: id)

            let deleted = await coordinator.deleteMeeting(id: id)

            XCTAssertFalse(deleted, "\(status) must not be deletable")
            let progress = try await store.progressStatus(id: id)
            XCTAssertEqual(progress, status)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        }
    }

    /// Break caught: the row is deleted first and the staged removal then
    /// fails, leaving a manifest with no row to show for it.
    func test_delete_meeting_keeps_the_row_when_the_staged_recording_cannot_be_removed() async throws {
        try XCTSkipIf(geteuid() == 0, "file permissions do not bind root")
        let store = try makeStore()
        let id = UUID()
        try await store.upsertProgress(
            meta: meta(id: id, status: .failed),
            status: .failed,
            failureReason: "boom"
        )
        _ = try stageRecording(id: id)
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor())
        // A directory entry cannot be unlinked from a read-only parent.
        XCTAssertEqual(chmod(stagingRoot.path, 0o555), 0)

        let deleted = await coordinator.deleteMeeting(id: id)

        XCTAssertFalse(deleted)
        let rows = try await store.list()
        XCTAssertEqual(rows.map(\.id), [id], "the user must still see the meeting and be able to retry")
    }

    /// Break caught: removing a staged directory just because its name was
    /// passed in. Audio without a meeting may be a lost recording.
    func test_delete_unknown_meeting_returns_false_and_leaves_the_staged_dir_alone() async throws {
        let store = try makeStore()
        let id = UUID()
        let dir = try stageRecording(id: id)
        let coordinator = makeCoordinator(store: store, processor: SpyDirectProcessor())

        let deleted = await coordinator.deleteMeeting(id: id)

        XCTAssertFalse(deleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("chunk-000.wav").path))
    }

    // MARK: - Fixtures

    private func makeStore() throws -> MeetingsStore {
        try MeetingsStore(rootDirectory: meetingsRoot)
    }

    private func makeCoordinator(
        store: MeetingsStore,
        processor: SpyDirectProcessor
    ) -> MeetingsCoordinator {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true
        let staging = stagingRoot
        return MeetingsCoordinator(
            config: config,
            detector: StubbedMeetingDetector(),
            stagingRoot: { staging },
            meetingsStore: store,
            directProcessor: processor,
            meetingsEnabled: { true }
        )
    }

    private func meta(id: UUID, status: MeetingProgressStatus) -> MeetingMetaWithLocalState {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        return MeetingMetaWithLocalState(
            id: id,
            startedAt: started,
            endedAt: started.addingTimeInterval(120),
            durationSeconds: 120,
            title: "Meeting",
            syncStatus: .new,
            serverVersion: 1,
            createdAt: started.addingTimeInterval(121),
            progressStatus: status
        )
    }

    /// A staged recording as a crashed or failed run leaves it: audio, a
    /// separate-track copy, a Soniox checkpoint and the finalize manifest.
    @discardableResult
    private func stageRecording(id: UUID) throws -> URL {
        let dir = stagingRoot.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x01]).write(to: dir.appendingPathComponent("chunk-000.wav"))
        try Data([0x02]).write(to: dir.appendingPathComponent("mic-chunk-000.wav"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("soniox-transcription.json"))
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        try MeetingFinalizeManifestStore().write(
            MeetingFinalizeManifest(
                recorderMeetingId: id,
                startedAt: started,
                endedAt: started.addingTimeInterval(120),
                durationSeconds: 120,
                language: nil,
                chunkFileNames: ["chunk-000.wav"],
                isFinal: true
            ),
            to: dir
        )
        return dir
    }

    private func fileNames(in directory: URL, mentioning id: UUID) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(id.uuidString) }
    }
}

/// Processor spy: records which meetings were handed to it and never touches
/// the staging dir, so what recovery or Delete leaves on disk stays visible.
@MainActor
private final class SpyDirectProcessor: MeetingDirectProcessing {
    private(set) var processedIds: [UUID] = []

    func shouldProcessDirectly() -> Bool { true }

    func process(
        event: MeetingRecorder.FinalizedEvent,
        startedAt: Date,
        language: String?,
        meetingsStore: MeetingsStore?
    ) async throws -> UUID {
        processedIds.append(event.meetingId)
        return event.meetingId
    }
}
