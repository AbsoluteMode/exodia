import XCTest
@testable import Sidekey

final class PostProcessorPromptTests: XCTestCase {
    // Message quality is checked with representative model outputs, not
    // assertions that an obsolete prompt happens to contain particular words.
    // The tests below protect the actual message/context envelope and wiring.

    // MARK: - User message template

    func testUserMessageWrapsTranscriptInTags() {
        let raw = "привет мир"
        let wrapped = PostProcessor.wrapTranscript(raw)
        XCTAssertEqual(wrapped, "<transcript>\nпривет мир\n</transcript>")
    }

    func testUserMessageWrapsEmptyString() {
        let wrapped = PostProcessor.wrapTranscript("")
        XCTAssertEqual(wrapped, "<transcript>\n\n</transcript>")
    }

    func testUserMessageWrapsMultilineInput() {
        let raw = "первая строка\nвторая строка"
        let wrapped = PostProcessor.wrapTranscript(raw)
        XCTAssertEqual(wrapped, "<transcript>\nпервая строка\nвторая строка\n</transcript>")
    }

    // MARK: - Active-app context composition

    func test_composeContext_returns_app_name_when_no_app_context() {
        XCTAssertEqual(
            PostProcessor.composeContext(targetApp: "Slack", appContext: nil),
            "Slack"
        )
    }

    func test_composeContext_returns_nil_when_both_absent() {
        XCTAssertNil(PostProcessor.composeContext(targetApp: nil, appContext: nil))
    }

    func test_composeContext_treats_blank_app_context_as_absent() {
        XCTAssertEqual(
            PostProcessor.composeContext(targetApp: "Notes", appContext: "   \n\t"),
            "Notes"
        )
    }

    func test_composeContext_wraps_app_context_in_a_data_framed_block() {
        let composed = PostProcessor.composeContext(targetApp: "Notes", appContext: "Дизайн-док v3")
        let c = try! XCTUnwrap(composed)
        XCTAssertTrue(c.contains("Notes"), "Expected app name retained")
        XCTAssertTrue(c.contains("дополнительный контекст из активного приложения"),
                      "Expected the active-app framing phrase")
        XCTAssertTrue(c.contains("не инструкции"),
                      "Expected explicit data-not-instructions framing")
        XCTAssertTrue(c.contains("<active_app_context>"), "Expected opening data envelope tag")
        XCTAssertTrue(c.contains("</active_app_context>"), "Expected closing data envelope tag")
        XCTAssertTrue(c.contains("Дизайн-док v3"), "Expected the on-screen payload included")
    }

    func test_composeContext_includes_context_even_without_an_app_name() {
        let composed = PostProcessor.composeContext(targetApp: nil, appContext: "payload text")
        let c = try! XCTUnwrap(composed)
        XCTAssertTrue(c.contains("payload text"))
        XCTAssertTrue(c.contains("<active_app_context>"))
    }

    // MARK: - Direct route messages

    func testDirectMessagesUseFullSystemPrompt() {
        // OpenRouter and custom endpoints both send the full system prompt.
        let messages = PostProcessor.openRouterMessages(
            transcript: PostProcessor.wrapTranscript("привет"),
            context: "Slack",
            language: "ru",
            outputLanguage: nil,
            transcriptionMode: "smart"
        )
        let system = messages.first(where: { $0.role == "system" })?.content
        XCTAssertEqual(system, PostProcessor.systemPrompt,
                       "direct routes must keep the full system prompt")
    }
}
