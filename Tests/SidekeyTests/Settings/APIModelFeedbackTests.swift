import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class APIModelFeedbackTests: XCTestCase {
    func testFeedbackDrawingsDifferAndDisabledDoesNotReactInBothAppearances() throws {
        let output = ProcessInfo.processInfo.environment["EXODIA_API_FEEDBACK_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for dark in [false, true] {
            var images: [String: Data] = [:]
            let states = [("rest", false, false, false, true), ("hover", true, false, false, true),
                          ("pressed", true, true, false, true), ("focus", false, false, true, true),
                          ("disabled", false, false, false, false), ("disabled-hover", true, true, true, false)]
            for (name, hover, press, focus, enabled) in states {
                let tile = VStack(spacing: 10) {
                    Text("OpenAI").font(.system(size: 13, weight: .semibold))
                    Text("Language models").font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2)
                    Text("Add API key").font(.system(size: 11)).foregroundStyle(MacSettingsTheme.accent)
                }
                .frame(width: 160, height: 160).foregroundStyle(MacSettingsTheme.text)
                .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(MacSettingsTheme.sep, lineWidth: 0.5) }
                .overlay { APIModelFeedbackOverlay(cornerRadius: 12, hovered: hover, pressed: press, focused: focus, enabled: enabled) }
                .opacity(enabled ? 1 : 0.42)
                let view = VStack(spacing: 12) {
                    tile
                    Text("Check & save").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white).frame(width: 160, height: 30)
                        .background(MacSettingsTheme.accentFill, in: RoundedRectangle(cornerRadius: 6))
                        .overlay { APIModelFeedbackOverlay(hovered: hover, pressed: press, focused: focus, enabled: enabled) }
                        .opacity(enabled ? 1 : 0.42)
                }.padding(8).background(MacSettingsTheme.bgCard)
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 176, height: 218)
                let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 176, height: 218), styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false; window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                images[name] = data
                if let output { try data.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")) }
                XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
                window.contentView = nil; window.close()
            }
            XCTAssertNotEqual(images["rest"], images["hover"])
            XCTAssertNotEqual(images["hover"], images["pressed"])
            XCTAssertNotEqual(images["rest"], images["focus"])
            XCTAssertNotEqual(images["rest"], images["disabled"])
            XCTAssertEqual(images["disabled"], images["disabled-hover"])
        }
    }
}
