import XCTest
@testable import Sidekey

final class OpenCodeAnswerTests: XCTestCase {
    private func line(_ type: String, _ part: [String: String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["type": type, "part": part]), as: UTF8.self)
    }

    func testFinalFolderAnswerSeparatesCopyablePathAndOpenAction() throws {
        let prose = "Project is here:\n\n```\n/tmp/example-project\n```"
        let text = prose + "\n\n```json\n" +
            #"{"kind":"useful.actions","schemaVersion":1,"items":[{"type":"path","path":"/tmp/example-project","description":"Open folder"}]}"# + "\n```"
        var mapper = OpenCodeEventMapper()
        let streaming = mapper.map(line: try line("text", ["text": text]))
        XCTAssertTrue(streaming.isEmpty)
        XCTAssertEqual(mapper.finalEvents(), [
            .finalAnswer(text: prose),
            .blockComplete(.usefulActions(UsefulActionsBlock(items: [.path(path: "/tmp/example-project", description: "Open folder")]))),
            .done(sources: [])
        ])
    }

    @MainActor
    func testActionsOnlyNeverLeakRawJSONThroughTheNarrationFallback() async throws {
        var mapper = OpenCodeEventMapper()
        let raw = "```json\n" + #"{"kind":"useful.actions","schemaVersion":1,"items":[{"type":"path","path":"/tmp/example-project"}]}"# + "\n```"
        let events = mapper.map(line: try line("text", ["text": raw])) + mapper.finalEvents()
        let store = AskResponseStore()
        await store.consume(AsyncStream { stream in events.forEach { stream.yield($0) }; stream.finish() })
        XCTAssertTrue(store.streamingText.isEmpty)
        XCTAssertEqual(store.blocks, [.usefulActions(UsefulActionsBlock(items: [.path(path: "/tmp/example-project", description: nil)]))])
    }

    func testToolNarrationDoesNotBecomeFinalAnswer() throws {
        for boundary in ["tool_use", "step_finish", "step_start"] {
            var mapper = OpenCodeEventMapper()
            _ = mapper.map(line: try line("text", ["text": "I will search several places."]))
            _ = mapper.map(line: try line(boundary, ["reason": "tool-calls", "tool": "read"]))
            _ = mapper.map(line: try line("text", ["text": "Found it."]))
            XCTAssertEqual(mapper.finalEvents(), [.finalAnswer(text: "Found it."), .done(sources: [])])
        }
    }

    func testMultipleAnswerPartsAndOrdinaryCodeSurvive() throws {
        var mapper = OpenCodeEventMapper()
        _ = mapper.map(line: try line("text", ["text": "Use this:"]))
        _ = mapper.map(line: try line("text", ["text": "```swift\nprint(1)\n```", "id": "last"]))
        _ = mapper.map(line: try line("text", ["text": "```swift\nprint(1)\n```", "id": "last"]))
        XCTAssertEqual(mapper.finalEvents(), [.finalAnswer(text: "Use this:\n\n```swift\nprint(1)\n```"), .done(sources: [])])
    }

    func testProviderPublishesActionsOnlyAfterSuccessfulExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "Done.\n\n```useful.actions\n" +
            #"{"kind":"useful.actions","schemaVersion":1,"items":[{"type":"copy","text":"example"}]}"# + "\n```"
        let event = try line("text", ["text": text])
        for exit: Int32 in [0, 1] {
            let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode-fixture") }, readKey: { _ in "fixture" },
                runStreaming: { _, _, _, _, _, onLine, onExit in onLine(event); onExit(exit); return CodexProcessHandle.noop })
            var events: [AgentSSEEvent] = []
            for await value in provider.run(prompt: "fixture", resumeSessionID: nil,
                                            options: AgentRunOptions(model: "fixture/model", workingDirectory: directory)) { events.append(value) }
            XCTAssertEqual(events.contains(.finalAnswer(text: "Done.")), exit == 0)
            XCTAssertEqual(events.contains(.blockComplete(.usefulActions(UsefulActionsBlock(items: [.copy(text: "example", description: nil)])))), exit == 0)
            XCTAssertEqual(events.contains(.done(sources: [])), exit == 0)
        }
    }
}
