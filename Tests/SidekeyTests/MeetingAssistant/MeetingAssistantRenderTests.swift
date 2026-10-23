import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class MeetingAssistantRenderTests: XCTestCase {
    func testNativePilotStatesOffscreen() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_MEETING_ASSISTANT_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTap Meeting Assistant render directory for offscreen visual checks.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "meeting-assistant-render-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MeetingAssistantModel(directory: directory, defaults: defaults)
        for scheme in [ColorScheme.light, .dark] {
            try render(model, scheme: scheme, name: "empty", directory: directory)
            model.spaces = [.init(version: 1, id: "project", name: "Whytap", purpose: "", instructions: "", sources: [])]
            model.selectedSpaceID = "project"
            model.pending = (0..<5).map { .init(question: "Какие изменения нужны для пилота \($0 + 1)?") }
            model.completed = (0..<20).map { .init(question: "Как подключить источники проекта \($0 + 1)?") }
            model.selected = .init(question: "Как подготовить Space проекта?", conclusion: "Создай Space через Codex или Claude Code.",
                                   points: ["Укажи **репозиторий и папки**, которые нужны для встречи.", "Проверь **выбранные модели** речи и ответов."],
                                   followups: [.init(title: "Какие папки включить?"), .init(title: "Как проверить доступ?")])
            model.answerVisible = true
            model.screenshots = (0..<6).map { index in .init(image: fixturePhoto(index), payload: .init(data: Data(), mimeType: "image/jpeg")) }
            model.layoutHeight = 1084; model.bodyLimit = 250
            try render(model, scheme: scheme, name: "populated", directory: directory)
            model.layoutHeight = 620; model.bodyLimit = 56
            try render(model, scheme: scheme, name: "short", directory: directory)
            model.spaces = []; model.pending = []; model.completed = []; model.selected = nil
            model.answerVisible = false; model.screenshots = []; model.layoutHeight = 1084
        }
    }
    private func fixturePhoto(_ index: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 320, height: 200))
        image.lockFocus()
        NSColor(calibratedWhite: index.isMultiple(of: 2) ? 0.9 : 0.25, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 320, height: 200).fill()
        ("ДЕМО \(index + 1)" as NSString).draw(at: NSPoint(x: 22, y: 135), withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: NSColor.systemBlue])
        NSColor.systemBlue.withAlphaComponent(0.2).setFill()
        NSRect(x: 22, y: 100, width: 210, height: 12).fill()
        NSRect(x: 22, y: 70, width: 165, height: 12).fill()
        image.unlockFocus()
        return image
    }
    func testHoverSessionStatesOffscreen() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_MEETING_ASSISTANT_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTap Meeting Assistant render directory for hover images.")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(220), 354] {
                let host = NSHostingView(rootView: VStack(spacing: 4) {
                    ForEach(0..<4) { index in
                        let phase: MeetingAssistantHoverState.Phase = [.off, .connecting, .listening, .stopping][index]
                        IslandMeetingAssistantControl(state: .init(available: true, phase: phase), setEnabled: { _ in })
                    }
                }.padding(.vertical, 8).frame(width: width).background(Color(white: 0.10))
                    .environment(\.colorScheme, scheme).transaction { $0.disablesAnimations = true })
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 204)
                host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("hover-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
    private func render(_ model: MeetingAssistantModel, scheme: ColorScheme, name: String, directory: URL) throws {
        let host = NSHostingView(rootView: MeetingAssistantView(model: model, openSettings: { _ in }).environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 354, height: 900)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.setFrameSize(host.fittingSize)
        }
        if name == "short" { XCTAssertLessThanOrEqual(host.fittingSize.height, 572, "The module must fit with 24pt screen margins") }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }
}
