import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class AgentModelMarkRenderTests: XCTestCase {
    func testOldDownloadCannotReplaceNewlySelectedModelAndPulseIsPreserved() async throws {
        var completeOld: CheckedContinuation<NSImage?, Never>?
        let old = TranscriptionProviderBrand.agent(.native, route: .init(account: .openAI, model: "gpt-exact"))
        let new = TranscriptionProviderBrand.agent(.native, route: .init(account: .anthropic, model: "claude-exact"))
        let view = ProviderBreathingMarkView(brand: old, reduceMotion: false, iconLoader: { brand in
            if brand == .openai { return await withCheckedContinuation { completeOld = $0 } }
            return nil
        })
        await Task.yield()
        let continuation = try XCTUnwrap(completeOld)
        view.apply(brand: new, reduceMotion: false)
        let image = NSImage(size: NSSize(width: 16, height: 16))
        continuation.resume(returning: image)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(view.brand, new)
        XCTAssertNil(view.modelImage)
        XCTAssertNotNil(view.markLayerForTesting.animation(forKey: ProviderBreathingMarkView.breathingAnimationKey))
        view.apply(brand: new, reduceMotion: true)
        XCTAssertNil(view.markLayerForTesting.animation(forKey: ProviderBreathingMarkView.breathingAnimationKey))
    }

    func testVoiceMarksOffscreen() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_MODEL_MARK_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_MODEL_MARK_RENDER_DIR for native voice mark images")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        ProviderBrandIconAsset.clearCacheForTesting()
        ProviderBrandIconAsset.setResourceDirectoryForTesting(root.appendingPathComponent("Resources/UsefulLinkIcons"))
        defer { ProviderBrandIconAsset.clearCacheForTesting(); ProviderBrandIconAsset.setResourceDirectoryForTesting(nil) }
        for width in [180.0, 280.0, 400.0] {
            for dark in [false, true] {
                let stack = NSStackView()
                stack.wantsLayer = true
                stack.layer?.backgroundColor = (dark ? NSColor.black : NSColor.white).cgColor
                stack.orientation = .vertical
                stack.spacing = 9
                stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
                for model in AgentModelBrand.allCases {
                    // Same built-in mark and native voice wing; no live fetch in this fixture.
                    let brand = TranscriptionProviderBrand(assetName: model.assetName, label: model.label)
                    let row = NSStackView()
                    row.spacing = 8
                    let label = NSTextField(labelWithString: model.label)
                    label.textColor = dark ? .white : .black
                    label.font = .systemFont(ofSize: 11)
                    label.widthAnchor.constraint(equalToConstant: 70).isActive = true
                    row.addArrangedSubview(label)
                    let host = NSHostingView(rootView: IslandAgentWingView(wing: .recording(transcript: "Скажи, где лежит папка проекта"),
                        faceWidth: width, activityLabel: "", recordingProviderBrand: brand, height: 28, onComposingFocusChange: { _ in })
                        .background(Color.black))
                    host.widthAnchor.constraint(equalToConstant: width).isActive = true
                    host.heightAnchor.constraint(equalToConstant: 28).isActive = true
                    row.addArrangedSubview(host)
                    stack.addArrangedSubview(row)
                }
                let size = NSSize(width: width + 102, height: 24 + 28 * 8 + 9 * 7)
                stack.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                    styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.backgroundColor = dark ? .black : .white
                window.contentView = stack
                stack.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
                let bitmap = try XCTUnwrap(stack.bitmapImageRepForCachingDisplay(in: stack.bounds))
                stack.cacheDisplay(in: stack.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("voice-marks-\(Int(width))-\(dark ? "dark" : "light").png"))
                XCTAssertFalse(window.isVisible)
                window.contentView = nil
                window.close()
            }
        }
    }
}
