import XCTest
@testable import Sidekey

@MainActor
final class MeetingAssistantAudioTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Condition timed out")
    }
    func testExplicitStartForwardsOnlyFinalsAndCancelReleasesAudio() async throws {
        let source = FixtureSubtitleAudio(), upstream = FixtureSubtitleUpstream()
        upstream.finalsJoin = .wordBoundary
        let audio = MeetingAssistantAudio(makeAudio: { source }, open: { upstream })
        var received: [String] = []
        audio.onText = { received.append($0) }
        XCTAssertEqual(source.started, 0)
        audio.start(); try await wait { audio.ready }
        source.pair.continuation.yield([0.1, 0.2])
        upstream.pair.continuation.yield(.partial("uncommitted"))
        upstream.pair.continuation.yield(.final("What changed?"))
        upstream.pair.continuation.yield(.final("Any risks?"))
        try await wait { received.count == 2 && !upstream.audio.isEmpty }
        XCTAssertEqual(received, ["What changed?", "What changed? Any risks?"])
        XCTAssertFalse(received.joined().contains("uncommitted"))
        await audio.cancel().value
        XCTAssertFalse(audio.active); XCTAssertTrue(upstream.closed); XCTAssertGreaterThan(source.stopped, 0)
    }
    func testMissingRouteNeverStartsCapture() async throws {
        let source = FixtureSubtitleAudio()
        let audio = MeetingAssistantAudio(makeAudio: { source }, open: { throw FeatureRouteError.notSet(.meetingAssistantAudio) })
        var issue: String?
        audio.onState = { _, message in if let message { issue = message } }
        audio.start(); try await wait { issue != nil }
        XCTAssertFalse(audio.active); XCTAssertEqual(source.started, 0)
        XCTAssertTrue(issue?.contains("Meeting Assistant audio") == true)
    }
    func testDeadlineRejectsLateConnectionAndDoesNotCapture() async throws {
        let source = FixtureSubtitleAudio(), upstream = FixtureSubtitleUpstream()
        var gate: CheckedContinuation<Void, Never>?
        let audio = MeetingAssistantAudio(connectionTimeout: .milliseconds(20), makeAudio: { source }, open: {
            await withCheckedContinuation { gate = $0 }
            return upstream
        })
        var issue: String?
        audio.onState = { _, message in if let message { issue = message } }
        audio.start(); try await wait { issue != nil }
        gate?.resume()
        try await wait { upstream.closed }
        XCTAssertFalse(audio.active); XCTAssertEqual(source.started, 0)
        await audio.cancel().value
    }
}
