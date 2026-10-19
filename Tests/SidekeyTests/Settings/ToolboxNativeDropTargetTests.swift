import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class ToolboxNativeDropTargetTests: XCTestCase {
    func testPreviewRemovalIsRequestedBeforeAnyLayoutCommit() throws {
        try withFixture { fixture in
            let info = fixture.info("vocab")
            XCTAssertEqual(fixture.view.draggingEntered(info), .copy)
            XCTAssertEqual(fixture.view.draggingUpdated(info), .copy)
            XCTAssertEqual(fixture.targets, [true])
            XCTAssertTrue(info.animatesToDestination)
            XCTAssertNil(fixture.defaults.object(forKey: HoverLayoutStore.defaultsKey))

            XCTAssertTrue(fixture.view.prepareForDragOperation(info))
            XCTAssertFalse(info.animatesToDestination)
            XCTAssertTrue(fixture.drops.isEmpty)
            XCTAssertNil(fixture.defaults.object(forKey: HoverLayoutStore.defaultsKey))

            fixture.beforeCommit = { XCTAssertFalse(info.animatesToDestination) }
            XCTAssertTrue(fixture.view.performDragOperation(info))
            XCTAssertEqual(fixture.drops, ["vocab"])
            XCTAssertEqual(fixture.targets, [true, false])
            XCTAssertEqual(fixture.store.slots.suffix(2), [.vocab, .settings])
            XCTAssertEqual(fixture.defaults.stringArray(forKey: HoverLayoutStore.defaultsKey),
                           fixture.store.slots.map(\.rawValue))
            fixture.view.concludeDragOperation(info)
            fixture.view.draggingEnded(info)
            XCTAssertEqual(fixture.drops.count, 1)
            XCTAssertEqual(fixture.targets, [true, false])
        }
    }

    func testCancelledAndUnpreparedDropsNeverChangePreferences() throws {
        try withFixture { fixture in
            let info = fixture.info("vocab")
            XCTAssertFalse(fixture.view.performDragOperation(info))
            XCTAssertEqual(fixture.view.draggingEntered(info), .copy)
            fixture.view.draggingExited(info)
            fixture.view.draggingEnded(info)
            XCTAssertFalse(fixture.view.performDragOperation(info))
            XCTAssertTrue(fixture.drops.isEmpty)
            XCTAssertTrue(info.animatesToDestination)
            XCTAssertNil(fixture.defaults.object(forKey: HoverLayoutStore.defaultsKey))
        }
    }

    func testInvalidPayloadAndPinnedSettingsAreNotTargets() throws {
        try withFixture { fixture in
            for raw in ["settings", "not-a-tool"] {
                let info = fixture.info(raw)
                XCTAssertEqual(fixture.view.draggingEntered(info), [])
                XCTAssertFalse(fixture.view.prepareForDragOperation(info))
                XCTAssertFalse(fixture.view.performDragOperation(info))
                XCTAssertTrue(info.animatesToDestination)
            }
            fixture.configure(target: .tool(.settings), enabled: true)
            XCTAssertFalse(fixture.view.isDropEnabled)
            XCTAssertTrue(fixture.view.registeredDraggedTypes.isEmpty)
            let info = fixture.info("vocab")
            XCTAssertEqual(fixture.view.draggingEntered(info), [])
            XCTAssertFalse(fixture.view.prepareForDragOperation(info))
            XCTAssertFalse(fixture.view.performDragOperation(info))
            XCTAssertNil(fixture.defaults.object(forKey: HoverLayoutStore.defaultsKey))
        }
    }

    func testChangedPayloadOrConfigurationInvalidatesPreparedDrop() throws {
        try withFixture { fixture in
            let info = fixture.info("vocab")
            XCTAssertTrue(fixture.view.prepareForDragOperation(info))
            info.draggingPasteboard.clearContents()
            info.draggingPasteboard.setString("filler", forType: .string)
            XCTAssertFalse(fixture.view.performDragOperation(info))
            XCTAssertTrue(fixture.drops.isEmpty)

            let second = fixture.info("vocab")
            XCTAssertTrue(fixture.view.prepareForDragOperation(second))
            fixture.configure(target: .add, enabled: false)
            XCTAssertFalse(fixture.view.performDragOperation(second))
            XCTAssertNil(fixture.defaults.object(forKey: HoverLayoutStore.defaultsKey))
        }
    }

    func testStaleSessionCannotCommitOrClearTheCurrentTarget() throws {
        try withFixture { fixture in
            let old = fixture.info("vocab")
            XCTAssertTrue(fixture.view.prepareForDragOperation(old))
            let current = fixture.info("filler")
            XCTAssertEqual(fixture.view.draggingEntered(current), .copy)
            let targetEvents = fixture.targets
            fixture.view.draggingExited(old)
            XCTAssertFalse(fixture.view.performDragOperation(old))
            XCTAssertEqual(fixture.targets, targetEvents)
            XCTAssertTrue(fixture.view.prepareForDragOperation(current))
            XCTAssertTrue(fixture.view.performDragOperation(current))
            XCTAssertEqual(fixture.drops, ["filler"])
        }
    }

    private func withFixture(_ check: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try check(fixture)
    }

    @MainActor
    private final class Fixture {
        let suite = "test.toolbox-native-drop.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: HoverLayoutStore
        let view = ToolboxDropTargetView(rootView: AnyView(Color.clear.frame(width: 56, height: 88)))
        var targets: [Bool] = []
        var drops: [String] = []
        var beforeCommit: () -> Void = {}
        var infos: [ToolboxFakeDraggingInfo] = []

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            store = HoverLayoutStore(defaults: defaults)
            configure(target: .add, enabled: true)
        }

        func configure(target: ToolboxHoverEditorItem, enabled: Bool) {
            view.configure(targetID: target, isEnabled: enabled,
                validate: { raw in HoverTool(rawValue: raw).map { $0 != .settings } ?? false },
                onTarget: { [weak self] in self?.targets.append($0) },
                onDrop: { [weak self] raw in
                    guard let self, let tool = HoverTool(rawValue: raw) else { return false }
                    beforeCommit()
                    drops.append(raw)
                    store.placeTool(tool, at: store.lockSlotIndex)
                    return true
                })
        }

        func info(_ raw: String) -> ToolboxFakeDraggingInfo {
            let info = ToolboxFakeDraggingInfo()
            info.draggingSequenceNumber = infos.count + 1
            info.draggingPasteboard.setString(raw, forType: .string)
            infos.append(info)
            return info
        }

        func close() {
            view.clearDragState()
            for info in infos { info.draggingPasteboard.releaseGlobally() }
            defaults.removePersistentDomain(forName: suite)
        }
    }
}


@MainActor
private final class ToolboxFakeDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = true
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [],
                                for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
