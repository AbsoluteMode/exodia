import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

final class ModelPickerSearchTests: XCTestCase {
    private func option(_ id: String, selected: Bool = false,
                        state: PickerOptionState = .new) -> PickerOption {
        PickerOption(model: id, state: state, isSelected: selected, hint: nil)
    }

    private var sections: [PickerSection] {
        [PickerSection(account: .openRouter, title: "OpenRouter", options: [
            option("anthropic/claude-sonnet-5.5"),
            option("qwen/qwen2.5-72b-instruct"),
            option("qwen/qwen2.7-72b-instruct"),
            option("qwen/qwen3.8-27b", selected: true),
            option("qwen/qwen3-27b:free"),
            option("qwen/qwen-27b"),
            option("qwen/qwen3-27b-retired", state: .notSupported(reason: "Removed")),
        ], refreshFailed: true),
         PickerSection(account: .anthropic, title: "Anthropic", options: [
            option("claude-sonnet-5-5")
         ], refreshFailed: false)]
    }

    func testSizeAndNameStayMatchedWithSpacesPunctuationAndReversedOrder() {
        for query in ["qwen 27", "27 qwen", " QWEN\t27\n", "qwen27", "qwen-27", "ｑｗｅｎ ２７"] {
            let matches = ModelPickerSearch.results(in: sections, query: query)
            XCTAssertTrue(matches.contains { $0.option.model == "qwen/qwen3.8-27b" }, query)
            XCTAssertFalse(matches.contains { $0.option.model.contains("72b") }, query)
            XCTAssertEqual(matches.count, 4, query)
        }
    }

    func testEveryTermMustMatchAndLiteralPunctuationIsNotRegex() {
        XCTAssertTrue(ModelPickerSearch.results(in: sections, query: "qwen 27 missing").isEmpty)
        XCTAssertEqual(ModelPickerSearch.results(in: sections, query: "qwen 27 free").map(\.option.model),
                       ["qwen/qwen3-27b:free"])
        XCTAssertEqual(ModelPickerSearch.results(in: sections, query: "sonnet 5.5").count, 2)
        XCTAssertEqual(ModelPickerSearch.results(in: sections, query: "[qwen] 27").count, 4)
    }

    func testNumericSuffixMustStayAttachedInsteadOfMatchingTheProviderName() {
        let section = PickerSection(account: .openRouter, title: "OpenRouter", options: [
            option("openai/gpt-4"), option("openai/gpt-4o"), option("openai/gpt-4o-mini")
        ], refreshFailed: false)
        XCTAssertEqual(ModelPickerSearch.results(in: [section], query: "gpt4o").map(\.option.model),
                       ["openai/gpt-4o", "openai/gpt-4o-mini"])
    }

    func testEmptyQueryPreservesOrderSelectionAndFailureMetadata() {
        let matches = ModelPickerSearch.results(in: sections, query: "  \n")
        XCTAssertEqual(matches.map(\.option.model), sections.flatMap(\.options).map(\.model))
        XCTAssertEqual(matches.filter { $0.option.isSelected }.map(\.option.model), ["qwen/qwen3.8-27b"])
        XCTAssertTrue(matches[0].refreshFailed)
        XCTAssertFalse(matches.last!.refreshFailed)
    }

    func testCloserPhraseMatchesRankFirstStably() {
        let matches = ModelPickerSearch.results(in: sections, query: "qwen 27")
        XCTAssertEqual(matches.first?.option.model, "qwen/qwen-27b")
        XCTAssertEqual(matches.dropFirst().map(\.option.model), [
            "qwen/qwen3.8-27b", "qwen/qwen3-27b:free", "qwen/qwen3-27b-retired"
        ])
    }

    func testSameModelOnDifferentAccountsRemainsDistinctAndProviderIsSearchable() {
        let server = ProviderAccount.server(UUID())
        let sections = [
            PickerSection(account: .openRouter, title: "OpenRouter", options: [option("qwen-27b")], refreshFailed: false),
            PickerSection(account: server, title: "My server", options: [option("qwen-27b")], refreshFailed: false)
        ]
        let both = ModelPickerSearch.results(in: sections, query: "qwen 27")
        XCTAssertEqual(Set(both.map(\.id)).count, 2)
        XCTAssertEqual(ModelPickerSearch.results(in: sections, query: "server qwen 27").map(\.account), [server])
    }

    func testNavigationSkipsUnsupportedRowsAndHandlesFilterChangesAndBounds() {
        let matches = ModelPickerSearch.results(in: sections, query: "qwen 27")
        let first = matches[0].id
        let last = matches[matches.count - 2].id
        XCTAssertEqual(ModelPickerSearch.moved(from: nil, by: 1, in: matches), first)
        XCTAssertEqual(ModelPickerSearch.moved(from: nil, by: -1, in: matches), last)
        XCTAssertEqual(ModelPickerSearch.moved(from: first, by: -1, in: matches), first)
        XCTAssertEqual(ModelPickerSearch.moved(from: last, by: 1, in: matches), last)
        XCTAssertNil(ModelPickerSearch.moved(from: first, by: 1, in: []))
        let filtered = ModelPickerSearch.results(in: sections, query: "free")
        XCTAssertEqual(ModelPickerSearch.moved(from: first, by: 1, in: filtered), filtered.first?.id)
    }
}

@MainActor
final class ModelSearchFieldTests: XCTestCase {
    func testNativeEditingCommandsReachPickerWithoutInterceptingOrdinaryEditing() {
        var query = ""
        var movements: [Int] = []
        var submits = 0
        var escapes = 0
        let search = ModelSearchField(text: Binding(get: { query }, set: { query = $0 }),
                                      onMove: { movements.append($0) },
                                      onSubmit: { submits += 1 }, onEscape: { escapes += 1 })
        let delegate = search.makeCoordinator()
        let field = NSSearchField()
        let editor = NSTextView()
        field.stringValue = "qwen 27"
        delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(query, "qwen 27")
        for command in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)),
                        #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: command))
        }
        XCTAssertEqual(movements, [1, -1])
        XCTAssertEqual(submits, 1)
        XCTAssertEqual(escapes, 1)
        XCTAssertFalse(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        editor.setMarkedText("qwen", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submits, 1, "Return must commit IME text before picking a model")
    }
}
