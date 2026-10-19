import AppKit
import XCTest
@testable import Sidekey

/// The Delete request of the meetings list: ask first, delete through the
/// injected handler only after a yes, and always tell the user when it fails.
@MainActor
final class MeetingsContentControllerDeleteTests: XCTestCase {

    final class CountingSource: MeetingsSidebarSource, @unchecked Sendable {
        private(set) var loadCount = 0
        private let meetings: [MeetingMetaWithLocalState]
        init(meetings: [MeetingMetaWithLocalState]) { self.meetings = meetings }
        func loadList() async throws -> [MeetingMetaWithLocalState] {
            loadCount += 1
            return meetings
        }
    }

    /// Everything the controller reports to its collaborators, in order.
    final class Calls {
        var deleted: [UUID] = []
        var confirmedTitles: [String] = []
        var failedTitles: [String] = []
    }

    /// Break caught: the list never reloads after a delete, so the deleted row
    /// stays on screen; or the title shown in the question is wrong.
    func test_confirmed_delete_asks_with_the_title_deletes_once_and_reloads_the_list() async {
        let id = UUID()
        let source = CountingSource(meetings: [makeMeeting(id: id, title: "Standup")])
        let calls = Calls()
        let controller = makeController(source: source, calls: calls, answer: true, deleteResult: true)
        _ = controller.view
        await waitUntil { source.loadCount >= 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let loadsBefore = source.loadCount

        controller.sidebarDidRequestDelete(id: id)
        await waitUntil { calls.deleted == [id] && source.loadCount > loadsBefore }

        XCTAssertEqual(calls.confirmedTitles, ["Standup"])
        XCTAssertEqual(calls.deleted, [id])
        XCTAssertGreaterThan(source.loadCount, loadsBefore, "the list must reload after the delete")
        XCTAssertTrue(calls.failedTitles.isEmpty)
    }

    /// Break caught: the question shows an empty name for a meeting the list
    /// itself calls "Untitled".
    func test_confirmation_calls_a_meeting_without_a_title_untitled() async {
        let id = UUID()
        let source = CountingSource(meetings: [makeMeeting(id: id, title: nil)])
        let calls = Calls()
        let controller = makeController(source: source, calls: calls, answer: false, deleteResult: true)
        _ = controller.view
        await waitUntil { source.loadCount >= 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)

        controller.sidebarDidRequestDelete(id: id)
        await waitUntil { !calls.confirmedTitles.isEmpty }

        XCTAssertEqual(calls.confirmedTitles, ["Untitled"])
    }

    /// Break caught: Cancel still deletes (the answer is ignored).
    func test_declined_delete_deletes_nothing() async {
        let id = UUID()
        let source = CountingSource(meetings: [makeMeeting(id: id, title: "Standup")])
        let calls = Calls()
        let controller = makeController(source: source, calls: calls, answer: false, deleteResult: true)
        _ = controller.view
        await waitUntil { source.loadCount >= 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)

        controller.sidebarDidRequestDelete(id: id)
        await waitUntil { !calls.confirmedTitles.isEmpty }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(calls.confirmedTitles, ["Standup"])
        XCTAssertTrue(calls.deleted.isEmpty)
        XCTAssertTrue(calls.failedTitles.isEmpty)
    }

    /// Break caught: a delete that fails looks like it worked (silent failure).
    func test_failed_delete_is_reported_to_the_user() async {
        let id = UUID()
        let source = CountingSource(meetings: [makeMeeting(id: id, title: "Standup")])
        let calls = Calls()
        let controller = makeController(source: source, calls: calls, answer: true, deleteResult: false)
        _ = controller.view
        await waitUntil { source.loadCount >= 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)

        controller.sidebarDidRequestDelete(id: id)
        await waitUntil { !calls.failedTitles.isEmpty }

        XCTAssertEqual(calls.deleted, [id])
        XCTAssertEqual(calls.failedTitles, ["Standup"])
    }

    // MARK: - Fixtures

    private func makeController(
        source: CountingSource,
        calls: Calls,
        answer: Bool,
        deleteResult: Bool
    ) -> MeetingsContentController {
        MeetingsContentController(
            source: source,
            markdownProvider: { _ in nil },
            transcriptProvider: { _ in nil },
            bundleURL: nil,
            bundleAccessRoot: nil,
            refreshHandler: nil,
            deleteHandler: { id in
                calls.deleted.append(id)
                return deleteResult
            },
            deletionPrompts: MeetingDeletionPrompts(
                confirm: { title, _ in
                    calls.confirmedTitles.append(title)
                    return answer
                },
                reportFailure: { title, _ in
                    calls.failedTitles.append(title)
                }
            )
        )
    }

    private func makeMeeting(id: UUID, title: String?) -> MeetingMetaWithLocalState {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        return MeetingMetaWithLocalState(
            id: id,
            startedAt: started,
            endedAt: started.addingTimeInterval(900),
            durationSeconds: 900,
            title: title,
            syncStatus: .new,
            serverVersion: 1,
            createdAt: started.addingTimeInterval(901)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
