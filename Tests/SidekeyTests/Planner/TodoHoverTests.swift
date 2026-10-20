import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class TodoHoverTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("planner.json") }
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }

    func testCompleteReopenAndOpeningBoundaryPreserveHistoryOnDisk() throws {
        let store = PlannerStore(url: url)
        let old = PlannerTask(title: "Earlier", createdAt: Date(timeIntervalSince1970: 100))
        let next = PlannerTask(title: "Next", createdAt: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(store.saveTask(old)); XCTAssertTrue(store.saveTask(next))
        let model = TodoHoverModel(store: store)
        model.begin()
        let firstCompletion = Date(timeIntervalSince1970: 1_790_000_000)
        model.toggle(old.id, now: firstCompletion)
        XCTAssertEqual(model.tasks.map(\.id), [next.id, old.id])
        XCTAssertEqual(model.tasks.last?.completedAt, firstCompletion)
        // It can be undone before the panel closes.
        model.toggle(old.id)
        XCTAssertEqual(model.tasks.map(\.id), [old.id, next.id])
        XCTAssertNil(model.tasks.first?.completedAt)
        let finalCompletion = firstCompletion.addingTimeInterval(90)
        model.toggle(old.id, now: finalCompletion)
        model.showingHistory = true
        XCTAssertEqual(model.tasks.map(\.id), [old.id])
        model.showingHistory = false
        XCTAssertEqual(model.tasks.count, 2, "History navigation is still the same opening")
        model.end(); model.begin()
        XCTAssertEqual(model.tasks.map(\.id), [next.id])
        model.showingHistory = true
        XCTAssertEqual(model.tasks.first?.completedAt, finalCompletion)
        let restored = TodoHoverModel(store: PlannerStore(url: url))
        restored.begin(); restored.showingHistory = true
        XCTAssertEqual(restored.tasks.first?.completedAt, finalCompletion)
        restored.toggle(old.id)
        XCTAssertTrue(restored.tasks.isEmpty)
        restored.showingHistory = false
        XCTAssertEqual(restored.tasks.map(\.id), [old.id, next.id])
    }

    func testLegacyArchiveHasUnknownCompletionTimeAndKeepsItWhileEditing() throws {
        let legacy = PlannerTask(title: "Old completed task", completed: true)
        var archive = PlannerStore.Archive(); archive.tasks = [legacy]
        let bytes = try JSONEncoder().encode(archive)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var tasks = try XCTUnwrap(json["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "completedAt"); json["tasks"] = tasks
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let store = PlannerStore(url: url)
        XCTAssertTrue(store.canWrite)
        var edited = try XCTUnwrap(store.archive.tasks.first)
        XCTAssertNil(edited.completedAt)
        edited.title = "Edited legacy task"
        XCTAssertTrue(store.saveTask(edited))
        XCTAssertNil(store.archive.tasks.first?.completedAt, "Do not invent an old completion time")
        let model = TodoHoverModel(store: store); model.begin()
        XCTAssertTrue(model.tasks.isEmpty)
        model.showingHistory = true
        XCTAssertEqual(model.tasks.count, 1)
    }

    func testDraftSurvivesCloseAndSaveFailureDoesNotCompleteOrClearIt() throws {
        var fail = false
        var activity: [Bool] = []
        let store = PlannerStore(url: url, write: { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url)
        })
        let model = TodoHoverModel(store: store, activityChanged: { activity.append($0) })
        model.begin(); model.draft = "  Keep draft  "
        model.end(); XCTAssertEqual(activity.last, true)
        model.begin(); XCTAssertEqual(model.draft, "  Keep draft  ")
        fail = true
        XCTAssertFalse(model.submit()); XCTAssertEqual(model.draft, "  Keep draft  ")
        XCTAssertTrue(store.archive.tasks.isEmpty)
        fail = false
        XCTAssertTrue(model.submit()); XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.lastAddedID, store.archive.tasks.last?.id)
        let id = try XCTUnwrap(model.tasks.first?.id)
        fail = true; model.toggle(id)
        XCTAssertFalse(try XCTUnwrap(model.tasks.first).completed)
        XCTAssertTrue(model.completedThisOpening.isEmpty)
        model.end(); XCTAssertEqual(activity.last, false)
        model.draft = String(repeating: "x", count: 501)
        XCTAssertFalse(model.submit()); XCTAssertNotNil(model.validationMessage)
        let invalid = model.draft
        model.draft = invalid
        XCTAssertNotNil(model.validationMessage, "An unchanged native binding write must preserve the error")
        model.draft = ""; XCTAssertNil(model.validationMessage)
        XCTAssertEqual(activity.last, false)
        model.draft = " \n\t "
        model.begin(); model.end()
        XCTAssertEqual(activity.last, false, "Invisible whitespace is not an unsaved task")
    }

    func testInlineRoutingKeyboardAndNativeHitBand() {
        XCTAssertEqual(HoverSlotRouter.effect(for: .tasks), .openPanel(.tasks))
        XCTAssertEqual(HoverToolRegistry.info(for: .tasks).kind, .inlinePanel)
        XCTAssertTrue(IslandHoverPanelMode.tasks.needsKeyboardFocus)
        XCTAssertTrue(IslandView.menuStaysOpen(.tasks, glance: false))
        let height = IslandView.hoverPanelHeight(for: .tasks, musicActive: false)
        XCTAssertEqual(height, IslandDropModeControl.detachedPanelGap + TodoHoverView.contentHeight)
        XCTAssertEqual(IslandView.hoverPanelHeight(for: .tasks, musicActive: true) - height,
                       IslandDropModeControl.musicStripHeight + IslandDropModeControl.musicStripBottomGap)
        for width: CGFloat in [310, 360, 500] {
            let pill = CGRect(x: 500, y: 600, width: width, height: 38)
            let zone = IslandHoverPanelHitZone(compactFrame: pill, bandHeight: height)
            XCTAssertEqual(zone.drawerFrame.width, width)
            XCTAssertFalse(IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                cursor: CGPoint(x: pill.midX, y: zone.drawerFrame.minY + 1), activeFrames: zone.activeFrames))
        }
    }

    func testNativeReturnActionAddsTaskWithoutShowingOrActivatingWindow() async throws {
        _ = NSApplication.shared
        let model = TodoHoverModel(store: PlannerStore(url: url)); model.begin()
        let host = NSHostingView(rootView: TodoHoverView(model: model, onBack: {}))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 310, height: 290),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try XCTUnwrap(fields(host).first { $0.placeholderString == "Add a task, press Enter" })
        XCTAssertTrue(window.makeFirstResponder(field))
        field.stringValue = "Written with native Return"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(model.draft, "Written with native Return")
        XCTAssertTrue(field.sendAction(field.action, to: field.target))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(model.store.archive.tasks.map(\.title), ["Written with native Return"])
        XCTAssertEqual(model.draft, "")
        // Native Return must keep both the rejected text and its explanation.
        field.stringValue = String(repeating: "x", count: 501)
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertTrue(field.sendAction(field.action, to: field.target))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNotNil(model.validationMessage)
        XCTAssertEqual(model.draft.count, 501)
        XCTAssertEqual(model.store.archive.tasks.count, 1)
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
    }

    func testOffscreenTodoFixtures() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTap_TODO_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTap_TODO_RENDER_DIR for synthetic offscreen To-do fixtures")
        }
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let store = PlannerStore(url: url)
        let model = TodoHoverModel(store: store); model.begin()
        for width: CGFloat in [310, 360, 500] {
            try await render(model, width: width, name: "empty", destination: destination)
        }
        for title in ["Купить кофе", "Review the launch checklist and confirm every calendar integration with the team before Friday", "Ответить на письмо", "Finish the draft"] {
            model.draft = title; XCTAssertTrue(model.submit())
        }
        let id = try XCTUnwrap(model.tasks.first?.id)
        model.toggle(id, now: Date(timeIntervalSince1970: 1_792_518_000))
        for width: CGFloat in [310, 360, 500] {
            try await render(model, width: width, name: "tasks", destination: destination)
            model.showingHistory = true
            try await render(model, width: width, name: "history", destination: destination)
            model.showingHistory = false
        }
        model.draft = String(repeating: "long ", count: 110); XCTAssertFalse(model.submit())
        try await render(model, width: 310, name: "validation", destination: destination)
        try await render(model, width: 310, name: "long-list", destination: destination)
    }

    private func render(_ model: TodoHoverModel, width: CGFloat, name: String, destination: URL) async throws {
        // Each offscreen host is a separate opening, just as in the real drawer.
        let fixture = TodoHoverModel(store: model.store)
        fixture.begin()
        fixture.showingHistory = name == "history"
        fixture.draft = model.draft
        if name == "tasks", let completed = model.store.archive.tasks.first(where: \.completed) {
            fixture.toggle(completed.id)
            fixture.toggle(completed.id, now: completed.completedAt ?? Date())
        }
        if name == "validation" { XCTAssertFalse(fixture.submit()) }
        if name == "long-list" {
            for index in 1...12 {
                fixture.draft = "Existing task \(index)"; XCTAssertTrue(fixture.submit())
            }
        }
        let host = NSHostingView(rootView: TodoHoverView(model: fixture, onBack: {})
            .background(Color(white: 0.12)).environment(\.colorScheme, .dark))
        let size = NSSize(width: width, height: TodoHoverView.contentHeight)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size); window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        if name == "long-list" {
            fixture.draft = "Newest task is visible after Return"
            XCTAssertTrue(fixture.submit())
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: destination.appendingPathComponent("\(name)-\(Int(width)).png"))
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
    }
}
