import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class MeetingAssistantTests: XCTestCase {
    private func fixture(account: ProviderAccount = .openRouter) throws -> (MeetingAssistantRunner, URL, UserDefaults) {
        StubURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "meeting-assistant-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock {
            session.invalidateAndCancel(); StubURLProtocol.reset()
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
        }
        let runner = MeetingAssistantRunner(http: .init(session: session), resolve: {
            ResolvedRoute(feature: .meetingAssistant, account: account, model: "fixture-model", apiKey: "fixture-key", server: nil)
        }, endpoint: { nil }, usageSink: { _ in })
        return (runner, root, defaults)
    }
    private func space(_ root: URL, id: String = "project") -> MeetingSpace {
        .init(version: 1, id: id, name: id, purpose: "Project", instructions: "", sources: [
            .init(id: "repo", kind: "repository", name: "Repo", location: try! SpaceRepository.root(root.path).path, scope: ["."], access: "read")
        ])
    }
    private var answer: [String: Any] { ["conclusion": "Готово", "points": ["Первый **важный** пункт"], "followups": ["Что дальше?", "Какие риски?"], "sources": []] }
    private func serve(_ value: [String: Any]) -> (Int, [String: String], Data) {
        (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: value))
    }
    private func routerAnswer() -> [String: Any] {
        ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "tool_calls": [
            ["id": "final", "type": "function", "function": ["name": "answer", "arguments": String(data: try! JSONSerialization.data(withJSONObject: answer), encoding: .utf8)!]]
        ]]]]]
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Condition timed out")
    }
    func testAllProvidersReceiveInitialImagesAndOnlyScopedTools() async throws {
        for account in [ProviderAccount.openRouter, .openAI, .anthropic] {
            let (runner, root, _) = try fixture(account: account)
            StubURLProtocol.handler = { _ in
                switch account {
                case .openAI: return self.serve(["status": "completed", "output": [["type": "function_call", "call_id": "answer1", "name": "answer", "arguments": String(data: try! JSONSerialization.data(withJSONObject: self.answer), encoding: .utf8)!]]])
                case .anthropic: return self.serve(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "answer1", "name": "answer", "input": self.answer]]])
                default: return self.serve(self.routerAnswer())
                }
            }
            let value = try await runner.answer(question: "Fixture question", space: space(root), transcript: "", history: [], images: [.init(data: Data("synthetic-image".utf8), mimeType: "image/jpeg")])
            XCTAssertEqual(value.followups.count, 2)
            let body = try XCTUnwrap(StubURLProtocol.capturedBodies.last)
            let text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
            XCTAssertTrue(text.contains(Data("synthetic-image".utf8).base64EncodedString()))
            XCTAssertFalse(text.contains("capture_screen")); XCTAssertFalse(text.contains("run_command"))
            XCTAssertFalse(text.contains("write_file")); XCTAssertFalse(text.contains("case_list_keys")); XCTAssertFalse(text.contains("web_search"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "No repository or agent history writes")
            if account == .openAI { XCTAssertTrue(text.contains("input_image")); XCTAssertTrue(text.contains("\"store\":false")) }
            if account == .anthropic { XCTAssertTrue(text.contains("\"media_type\":\"image/jpeg\"")) }
        }
    }
    func testDeliveredPhotosAreConsumedAndClarificationSurvivesCollapseAndRootReopen() async throws {
        let (runner, root, defaults) = try fixture()
        StubURLProtocol.handler = { _ in self.serve(self.routerAnswer()) }
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner)
        model.spaces = [space(root)]; model.selectedSpaceID = "project"
        model.screenshots = [.init(image: NSImage(size: NSSize(width: 10, height: 10)), payload: .init(data: Data("fixture".utf8), mimeType: "image/jpeg"))]
        model.draft = "Вопрос"; model.submit()
        try await wait { model.busy == nil }
        XCTAssertTrue(model.screenshots.isEmpty); XCTAssertEqual(model.completed.count, 1)
        let rootQuestion = try XCTUnwrap(model.completed.first)
        model.followupDraft = "Уточнение"; model.submitFollowup()
        try await wait { model.busy == nil }
        let continuation = model.selected
        model.answerVisible = false; model.restoreAnswer()
        XCTAssertEqual(model.selected, continuation); XCTAssertEqual(model.previous.count, 1)
        model.ask(rootQuestion)
        XCTAssertEqual(model.selected, continuation); XCTAssertEqual(model.previous.count, 1)
        XCTAssertEqual(model.completed.count, 1)
        XCTAssertEqual(StubURLProtocol.capturedBodies.count, 2, "Cached reopen sends no model request")
        let body = String(decoding: StubURLProtocol.capturedBodies[1], as: UTF8.self)
        XCTAssertFalse(body.contains(Data("fixture".utf8).base64EncodedString()), "Old photos are not replayed in text history")
    }
    func testCancelAndSpaceSwitchRejectLateAnswersAndRetainPhotosOnlyInOriginalDraft() async throws {
        let (runner, root, defaults) = try fixture()
        StubURLProtocol.handler = { _ in Thread.sleep(forTimeInterval: 0.1); return self.serve(self.routerAnswer()) }
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner)
        model.spaces = [space(root), space(root, id: "other")]; model.selectedSpaceID = "project"
        model.screenshots = [.init(image: NSImage(size: NSSize(width: 10, height: 10)), payload: .init(data: Data("fixture".utf8), mimeType: "image/jpeg"))]
        model.draft = "Отмени"; model.submit(); model.cancel()
        try await Task.sleep(for: .milliseconds(180))
        model.restoreAnswer()
        XCTAssertFalse(model.notice.isEmpty); XCTAssertTrue(model.completed.isEmpty); XCTAssertEqual(model.screenshots.count, 1)
        model.draft = "Смени Space"; model.submit(); model.selectSpace("other")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(model.completed.isEmpty); XCTAssertTrue(model.screenshots.isEmpty)
        model.selectSpace("project")
        XCTAssertTrue(model.completed.isEmpty); XCTAssertFalse(model.notice.isEmpty)
        XCTAssertTrue(model.screenshots.isEmpty)
    }
    func testActiveManifestEditInvalidatesConversation() async throws {
        let (runner, root, defaults) = try fixture()
        var value = space(root)
        let file = root.appendingPathComponent("project.json")
        try JSONEncoder().encode(value).write(to: file)
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner)
        await model.reloadSpaces()
        model.completed = [.init(question: "Previous", conclusion: "Previous answer")]
        value.instructions = "New scope instructions"
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        await model.reloadSpaces()
        XCTAssertTrue(model.completed.isEmpty); XCTAssertEqual(model.currentSpace, value)
    }
    func testMalformedAnswerIsNotDelivered() throws {
        var invalid = MeetingAssistantAnswer(conclusion: "Answer", points: [], followups: [], sources: [])
        XCTAssertThrowsError(try invalid.validated())
        invalid.followups = ["Same", "Same"]
        XCTAssertThrowsError(try invalid.validated())
        XCTAssertEqual(AIFeature.meetingAssistantAudio.mode, .realtime)
        XCTAssertEqual(AIFeature.meetingAssistant.mode, .llmWithTools)
        XCTAssertEqual(HoverSlotRouter.effect(for: .meetingAssistant), .openMeetingAssistant)
        XCTAssertEqual(WhytapLink.destination(for: .meetingAssistant), .meetingAssistant)
    }
}
