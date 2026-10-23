import XCTest
@testable import Sidekey

@MainActor
final class MeetingAssistantMeetingScopeTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Condition timed out")
    }

    func testMeetingEndStopsOnceAndAnotherMeetingCannotEnableIt() async throws {
        let probe = MeetingAssistantFixtureProbe()
        let scope = MeetingAssistantMeetingScope(endGrace: .milliseconds(20), makeProbe: { probe })
        var ended = 0; scope.onEnd = { ended += 1 }
        scope.begin(); scope.begin()
        XCTAssertEqual(probe.subscriptions, 1)
        probe.emit(true); probe.emit(false)
        try await wait { ended == 1 }
        XCTAssertEqual(probe.stops, 1)
        probe.emit(true); probe.emit(false)
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(ended, 1); XCTAssertEqual(probe.subscriptions, 1)
    }

    func testBriefReconnectCancelsEndAndExplicitOffCancelsDelayedEnd() async throws {
        let probe = MeetingAssistantFixtureProbe()
        let scope = MeetingAssistantMeetingScope(endGrace: .milliseconds(60), makeProbe: { probe })
        var ended = 0; scope.onEnd = { ended += 1 }
        scope.begin(); probe.emit(true); probe.emit(false)
        try await Task.sleep(for: .milliseconds(10))
        probe.emit(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(ended, 0)
        probe.emit(false)
        try await Task.sleep(for: .milliseconds(10))
        scope.stop()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(ended, 0); XCTAssertEqual(probe.stops, 1)
    }

    func testManualListeningBeforeRecognizedContextIsNotImmediatelyStopped() async throws {
        let probe = MeetingAssistantFixtureProbe()
        let scope = MeetingAssistantMeetingScope(endGrace: .milliseconds(10), makeProbe: { probe })
        var ended = 0; scope.onEnd = { ended += 1 }
        scope.begin(); probe.emit(false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(ended, 0)
        scope.stop()
    }

    func testHoverStateHasVisibleConnectingAndDisabledCleanup() {
        XCTAssertFalse(MeetingAssistantHoverState().visible)
        XCTAssertTrue(MeetingAssistantHoverState(available: true).visible)
        XCTAssertFalse(MeetingAssistantHoverState(available: true).isOn)
        for phase in [MeetingAssistantHoverState.Phase.connecting, .listening] {
            XCTAssertTrue(MeetingAssistantHoverState(phase: phase).isOn)
        }
        let stopping = MeetingAssistantHoverState(phase: .stopping)
        XCTAssertTrue(stopping.visible); XCTAssertFalse(stopping.canToggle); XCTAssertFalse(stopping.isOn)
    }

    func testHoverRowIsIncludedInOnlyTheControlsHitBand() {
        for count in [1, 5, 13, 25] {
            for music in [false, true] {
                let off = IslandView.hoverPanelHeight(for: .controls, musicActive: music, toolCount: count)
                XCTAssertEqual(IslandView.hoverPanelHeight(for: .controls, musicActive: music, toolCount: count,
                    meetingAssistantControlVisible: true), off + IslandMeetingAssistantControl.height)
                for mode in [IslandHoverPanelMode.monitor, .history, .calendar, .notifications] {
                    XCTAssertEqual(IslandView.hoverPanelHeight(for: mode, musicActive: music, toolCount: count,
                        meetingAssistantControlVisible: true), IslandView.hoverPanelHeight(for: mode, musicActive: music, toolCount: count))
                }
            }
        }
    }
}

@MainActor
final class MeetingAssistantFixtureProbe: MicInUseProbing {
    private var continuation: AsyncStream<Bool>.Continuation?
    private(set) var subscriptions = 0
    private(set) var stops = 0
    func subscribe() -> AsyncStream<Bool> {
        subscriptions += 1
        let pair = AsyncStream<Bool>.makeStream(); continuation = pair.continuation
        return pair.stream
    }
    func emit(_ value: Bool) { continuation?.yield(value) }
    func stop() { stops += 1; continuation?.finish(); continuation = nil }
}
