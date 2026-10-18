import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class ToolboxHoverEditorTests: XCTestCase {
    func testAddedToolOccupiesThePreviousAddTargetAcrossRowBoundaries() throws {
        let available = HoverTool.allCases.filter { $0 != .settings && $0 != .vocab }
        for count in [0, 1, 2, 5, 6, 8, 11] {
            try withEditor(tools: Array(available.prefix(count)), reduceMotion: true) { fixture in
                let before = try fixture.frames()
                let add = try XCTUnwrap(before[Self.addLabel])
                try fixture.saveImage("\(count)-before")

                XCTAssertTrue(fixture.store.placeTool(.vocab, at: fixture.store.lockSlotIndex))
                fixture.settle()

                let after = try fixture.frames()
                assertSameFrame(try XCTUnwrap(after["Vocab"]), add)
                XCTAssertEqual(fixture.store.slots.last, .settings)
                XCTAssertNotNil(after[Self.addLabel])
                XCTAssertEqual(after.count, count + 3) // tools + newly added Vocab + Add + Settings
                try fixture.saveImage("\(count)-after")
            }
        }
    }

    func testRemovingAToolReturnsTheAddTargetToItsPlace() throws {
        try withEditor(tools: [.inputLang, .notes, .vocab], reduceMotion: true) { fixture in
            let before = try fixture.frames()
            let vocab = try XCTUnwrap(before["Vocab"])
            fixture.store.removeTool(.vocab)
            fixture.settle()
            let after = try fixture.frames()
            assertSameFrame(try XCTUnwrap(after[Self.addLabel]), vocab)
            XCTAssertNil(after["Vocab"])
            XCTAssertEqual(fixture.store.slots, [.inputLang, .notes, .settings])
        }
    }

    func testReorderingKeepsPositionsWithReduceMotionOnAndOff() throws {
        for reduced in [false, true] {
            try withEditor(tools: [.inputLang, .notes, .vocab], reduceMotion: reduced) { fixture in
                let first = try XCTUnwrap(fixture.frames()["Input Lang"])
                XCTAssertTrue(fixture.store.placeTool(.vocab, at: 0))
                fixture.settle(0.25)
                assertSameFrame(try XCTUnwrap(fixture.frames()["Vocab"]), first)
                XCTAssertEqual(fixture.store.slots, [.vocab, .inputLang, .notes, .settings])
            }
        }
    }

    private static let addLabel = "Drop a tool here to add it to hover"

    private func assertSameFrame(_ actual: CGRect, _ expected: CGRect,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
    }

    private func withEditor(tools: [HoverTool], reduceMotion: Bool,
                            check: (EditorFixture) throws -> Void) throws {
        let suite = "test.toolbox-editor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HoverLayoutStore(defaults: defaults)
        store.replaceEditableSlots(with: tools)
        let fixture = EditorFixture(store: store, reduceMotion: reduceMotion)
        defer { fixture.close() }
        fixture.settle()
        try check(fixture)
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertFalse(fixture.window.isKeyWindow)
    }

    /// No production app, credentials, knowledge stores or native input events.
    /// The actual editor is laid out/drawn in an unordered, offscreen window.
    @MainActor
    private final class EditorFixture {
        let store: HoverLayoutStore
        let window: NSWindow
        let host: NSHostingView<AnyView>

        init(store: HoverLayoutStore, reduceMotion: Bool) {
            self.store = store
            window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 420, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            host = NSHostingView(rootView: AnyView(EmptyView()))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: 420, height: 640)
            window.contentView = host
            host.rootView = AnyView(
                ToolboxHoverEditor(hoverStore: store, reduceMotion: reduceMotion) { item in
                    Group {
                        switch item {
                        case .tool(let tool):
                            let info = HoverToolRegistry.info(for: tool)
                            ToolboxTileView(title: info.title, sfSymbol: info.sfSymbol,
                                            isSelected: false, isLocked: tool == .settings,
                                            isAdded: false, onTap: {})
                        case .add:
                            ToolboxAddTile()
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(white: 0.11))
                .environment(\.colorScheme, .dark)
            )
        }

        func settle(_ seconds: TimeInterval = 0.06) {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
            host.layoutSubtreeIfNeeded()
        }

        func frames() throws -> [String: CGRect] {
            var result: [String: CGRect] = [:]
            func walk(_ view: NSView) {
                if let cell = view as? ToolboxDropTargetView {
                    let label: String
                    switch cell.targetID {
                    case .tool(let tool): label = HoverToolRegistry.info(for: tool).title
                    case .add: label = ToolboxHoverEditorTests.addLabel
                    }
                    result[label] = host.convert(cell.bounds, from: cell)
                    XCTAssertEqual(cell.isDropEnabled, cell.targetID != .tool(.settings))
                    XCTAssertEqual(cell.registeredDraggedTypes.contains(.string), cell.isDropEnabled)
                    XCTAssertNotNil(cell.hitTest(NSPoint(x: 28, y: 44)))
                }
                for child in view.subviews { walk(child) }
            }
            walk(host)
            XCTAssertFalse(result.isEmpty, "Actual native editor cells must have measurable frames")
            return result
        }

        func saveImage(_ name: String) throws {
            guard let output = ProcessInfo.processInfo.environment["EXODIA_TOOLBOX_PROOF_DIR"] else { return }
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }
}
