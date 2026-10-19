import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class ToolHotkeyRenderTests: XCTestCase {
    func testOffscreenToolShortcutStates() throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_TOOL_HOTKEY_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_TOOL_HOTKEY_RENDER_DIR for offscreen visual checks.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = VStack(alignment: .leading, spacing: 8) {
            Text("Tools").font(.system(size: 15, weight: .semibold))
            Text("Shortcuts stay with the function, even when you move or remove its hover tile.")
                .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
            row(.brightness, shortcut: .combo(.optionD))
            row(.vocab, shortcut: nil)
            row(.settings, shortcut: .combo(.optionQ), conflict: true)
            row(.notifs, shortcut: nil, recording: true)
            row(.meetingRecord, shortcut: .combo(.optionThree))
            row(.monitor, shortcut: .combo(.optionFive), unavailable: true)
        }
        .padding(24)
        .frame(width: 720)
        .background(MacSettingsTheme.bgCard)
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: NSSize(width: 720, height: 640))
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("tool-hotkeys.png"))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    private func row(_ tool: HoverTool, shortcut: HotkeyShortcut?, conflict: Bool = false,
                     recording: Bool = false, unavailable: Bool = false) -> some View {
        let info = HoverToolRegistry.info(for: tool)
        return HotkeySettingRow(iconName: info.sfSymbol,
            title: tool == .meetingRecord ? "Record (additional shortcut)" : info.title,
            detail: info.description, gesture: .tap, allowsGestureSwitch: false,
            shortcutContents: shortcut?.contents ?? [], isRecording: recording,
            hasConflict: conflict, onGestureChange: { _ in }, onRecord: {},
            registrationError: unavailable ? "Shortcut unavailable. Check Accessibility or record another shortcut." : nil,
            onClear: shortcut == nil ? nil : {})
    }
}
