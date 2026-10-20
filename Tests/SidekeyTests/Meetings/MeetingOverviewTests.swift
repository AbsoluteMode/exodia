import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class MeetingOverviewTests: XCTestCase {
    final class Source: MeetingsSidebarSource {
        var meetings: [MeetingMetaWithLocalState] = []
        var shouldFail = false
        func loadList() async throws -> [MeetingMetaWithLocalState] {
            if shouldFail { throw CocoaError(.fileReadUnknown) }
            return meetings
        }
    }

    private let now = Date(timeIntervalSince1970: 1_792_490_400)

    private func meeting(_ index: Int, status: MeetingProgressStatus = .ready, title: String? = nil) -> MeetingMetaWithLocalState {
        let date = now.addingTimeInterval(-Double(index) * 3600)
        return MeetingMetaWithLocalState(
            id: UUID(), startedAt: date, endedAt: date.addingTimeInterval(900),
            durationSeconds: 900, title: title ?? "Meeting \(index)", syncStatus: .new,
            serverVersion: 1, createdAt: date.addingTimeInterval(901), progressStatus: status
        )
    }

    func testOverviewShowsNewestFiveWhileHistoryKeepsEveryMeeting() async throws {
        let source = Source()
        let meetings = (0..<8).map { meeting($0, status: $0 == 0 ? .updating : .ready) }
        source.meetings = meetings.reversed()
        let model = MeetingListModel(source: source, nowProvider: { self.now })
        model.refresh()
        try await model.awaitLoad()
        XCTAssertEqual(model.recentRows.map(\.id), meetings.prefix(5).map(\.id))
        XCTAssertEqual(model.recentRows.first?.progressStatus, .updating)
        XCTAssertEqual(model.sections.flatMap(\.rows).count, 8)
        XCTAssertEqual(model.page, .overview)
        model.showHistory()
        XCTAssertEqual(model.sections.flatMap(\.rows).count, 8)
        model.showOverview()
        XCTAssertEqual(model.recentRows.count, 5)
    }

    func testFailedRefreshKeepsReadableMeetingsAndAllowsRetry() async throws {
        let source = Source()
        source.meetings = [meeting(0)]
        let model = MeetingListModel(source: source)
        model.refresh()
        try await model.awaitLoad()
        let previous = model.recentRows
        source.shouldFail = true
        model.refresh()
        try await model.awaitLoad()
        XCTAssertEqual(model.loadState, .failed)
        XCTAssertEqual(model.recentRows, previous)
        source.shouldFail = false
        source.meetings = []
        model.refresh()
        try await model.awaitLoad()
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertTrue(model.recentRows.isEmpty)
        XCTAssertTrue(model.sections.isEmpty)
    }

    func testInitialFailureIsDistinctFromAnEmptyLoadedStore() async throws {
        let source = Source()
        source.shouldFail = true
        let model = MeetingListModel(source: source)
        model.refresh()
        try await model.awaitLoad()
        XCTAssertEqual(model.loadState, .failed)
        XCTAssertTrue(model.meetings.isEmpty)
        source.shouldFail = false
        model.refresh()
        try await model.awaitLoad()
        XCTAssertEqual(model.loadState, .loaded)
    }

    func testHistorySelectionReturnsToHistoryAndNotesHomeResetsOverview() async {
        let source = Source()
        source.meetings = [meeting(0)]
        let controller = makeController(source)
        controller.showHistoryScreen()
        controller.sidebarDidSelectMeeting(id: source.meetings[0].id)
        controller.returnToMeetingList()
        XCTAssertEqual(controller.listPage, .history)
        controller.showListScreen()
        XCTAssertEqual(controller.listPage, .overview)
    }

    func testDirectNoteLinkReturnsToOverviewAfterEarlierHistoryVisit() async {
        let source = Source()
        source.meetings = [meeting(0)]
        let controller = makeController(source)
        controller.showHistoryScreen()
        controller.selectMeeting(id: source.meetings[0].id)
        XCTAssertEqual(controller.listPage, .overview)
        // Back must also invalidate the queued detail load.
        controller.returnToMeetingList()
        await Task.yield()
        XCTAssertEqual(controller.listPage, .overview)
    }

    private func makeController(_ source: Source) -> MeetingsContentController {
        MeetingsContentController(source: source, markdownProvider: { _ in "# Example" },
            transcriptProvider: { _ in nil }, bundleURL: nil, bundleAccessRoot: nil)
    }

    /// Synthetic native rendering only. Never launches an app or shows a window.
    func testOffscreenOverviewHistoryAndLoadStates() async throws {
        guard let path = ProcessInfo.processInfo.environment["MEETINGS_RENDER_DIR"] else {
            throw XCTSkip("Set MEETINGS_RENDER_DIR for native layout inspection")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = Source()
        source.meetings = (0..<12).map {
            meeting($0, status: $0 == 0 ? .updating : ($0 == 1 ? .failed : .ready),
                title: $0 == 2 ? "Обсуждение функционала и удобства конструктора форм: очень длинное название встречи для проверки переноса" : nil)
        }
        let model = MeetingListModel(source: source, nowProvider: { self.now })
        model.refresh()
        try await model.awaitLoad()
        for width in [600, 800] {
            try render(model, width: width, to: folder.appendingPathComponent("overview-\(width).png"))
            model.showHistory()
            try render(model, width: width, to: folder.appendingPathComponent("history-\(width).png"))
            model.showOverview()
        }
        model.select(source.meetings[1].id)
        try render(model, width: 600, to: folder.appendingPathComponent("selected-failure.png"))
        model.select(source.meetings[0].id)
        try render(model, width: 600, to: folder.appendingPathComponent("selected-updating.png"))
        model.select(nil)
        source.shouldFail = true
        model.refresh()
        try await model.awaitLoad()
        try render(model, width: 600, to: folder.appendingPathComponent("refresh-error.png"))
        source.shouldFail = false
        source.meetings = []
        model.refresh()
        try await model.awaitLoad()
        try render(model, width: 600, to: folder.appendingPathComponent("empty.png"))
        source.shouldFail = true
        model.refresh()
        try await model.awaitLoad()
        try render(model, width: 600, to: folder.appendingPathComponent("load-error.png"))
    }

    private func render(_ model: MeetingListModel, width: Int, to url: URL) throws {
        let size = NSSize(width: width, height: 600)
        let view = MeetingListView(model: model, onSelect: { _ in })
            .frame(width: size.width, height: size.height)
            .background(Color(white: 0.12))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
