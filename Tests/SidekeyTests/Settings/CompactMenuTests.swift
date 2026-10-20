import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class CompactMenuTests: XCTestCase {
    private final class Frames {
        var values: [String: CGRect] = [:]
    }

    private struct FrameKey: PreferenceKey {
        static var defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private func measure(_ name: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: FrameKey.self, value: [name: proxy.frame(in: .named("row"))])
        }
    }

    func testNotificationMenuAndSwitchShareTheRowCenterForBothSizes() throws {
        for presentation in [NotifyPresentation.card, .icon] {
            let frames = Frames()
            let view = MacCard {
                MacRow(title: "Telegram — все входящие", subtitle: "Running") {
                    NotificationPresentationControl(selection: .constant(presentation), sourceName: "Telegram")
                        .background(measure("menu"))
                    MacSwitch(isOn: .constant(true)).background(measure("switch"))
                }
            }
            .coordinateSpace(name: "row")
            .onPreferenceChange(FrameKey.self) { frames.values = $0 }
            .padding(24)
            try render(view, size: NSSize(width: 650, height: 120), name: "notification-\(presentation.rawValue)")
            let menu = try XCTUnwrap(frames.values["menu"])
            let toggle = try XCTUnwrap(frames.values["switch"])
            XCTAssertEqual(menu.height, 30, accuracy: 0.5)
            XCTAssertEqual(menu.midY, toggle.midY, accuracy: 0.5)
            XCTAssertLessThan(menu.maxX, toggle.minX)
        }
    }

    func testNativePopupPreservesSelectionAndTargetAction() throws {
        final class Target: NSObject {
            var selected: String?
            @objc func changed(_ sender: NSPopUpButton) { selected = sender.titleOfSelectedItem }
        }
        let popup = MacPopupButton()
        popup.addItems(withTitles: ["Rectangle", "Oval"])
        popup.setAccessibilityLabel("Shape")
        let target = Target()
        popup.target = target
        popup.action = #selector(Target.changed(_:))
        let size = popup.intrinsicContentSize
        popup.selectItem(at: 1)
        XCTAssertEqual(popup.titleOfSelectedItem, "Oval")
        XCTAssertEqual(popup.intrinsicContentSize, size, "The widest item keeps the toolbar from shifting")
        XCTAssertEqual(size.height, 30, accuracy: 0.5)
        XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
        XCTAssertEqual(target.selected, "Oval")
        XCTAssertEqual(popup.accessibilityLabel(), "Shape")
    }

    func testOffscreenCompactMenuStates() throws {
        guard ProcessInfo.processInfo.environment["EXODIA_COMPACT_MENU_RENDER_DIR"] != nil else {
            throw XCTSkip("Set EXODIA_COMPACT_MENU_RENDER_DIR for visual proof")
        }
        for dark in [true, false] {
            let view = VStack(alignment: .leading, spacing: 12) {
                MacPopup(items: [.init(value: 1, label: "Short")], selection: .constant(1), appearance: .adaptive)
                MacPopup(items: [.init(value: 1, label: "A very long model name with a saved provider selection")],
                         selection: .constant(1), maxWidth: 260, appearance: .adaptive)
                MacPopup(items: [.init(value: 1, label: "Unavailable")], selection: .constant(1), appearance: .adaptive)
                    .disabled(true)
            }.padding(24)
            try render(view, size: NSSize(width: 320, height: 200), name: "adaptive-\(dark)", dark: dark)
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool = true) throws {
        let host = NSHostingView(rootView: view
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(dark ? Color(white: 0.12) : Color(white: 0.96))
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        if let output = ProcessInfo.processInfo.environment["EXODIA_COMPACT_MENU_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
