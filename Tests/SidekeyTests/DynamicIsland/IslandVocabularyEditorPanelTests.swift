import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class IslandVocabularyEditorPanelTests: XCTestCase {
    func testVocabularyEditorHasNoBackButtonAndHintsEnterSubmit() throws {
        let source = try vocabularyEditorSource()

        XCTAssertFalse(source.contains("IslandVocabularyBackButton"))
        XCTAssertFalse(source.contains("onBack"))
        XCTAssertTrue(source.contains("Search or add, press Enter"))
    }

    func testVocabularyInputCursorIsVerticallyCentered() throws {
        let source = try vocabularyEditorSource()

        XCTAssertTrue(source.contains("drawInsertionPoint"))
        XCTAssertTrue(source.contains("bounds.midY"))
        XCTAssertTrue(source.contains("inputTextVerticalInset"))
    }

    func testTypingAndEnterKeepNativeEditorFocusedAndSaveTheTerm() async throws {
        let fixture = try EditorFixture()
        defer { fixture.close() }
        await fixture.settle()
        let editor = try fixture.editor()
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertEqual(fixture.focusChanges.last, true)

        editor.insertText("ExodiaRegressionTerm", replacementRange: NSRange(location: 0, length: 0))
        await fixture.settle()
        XCTAssertEqual(fixture.viewModel.query, "ExodiaRegressionTerm")
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertFalse(fixture.focusChanges.contains(false))

        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await fixture.settle()
        XCTAssertEqual(fixture.vocabulary.terms, ["ExodiaRegressionTerm"])
        XCTAssertEqual(editor.string, "")
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertFalse(fixture.focusChanges.contains(false))
    }

    func testEscapeReleasesFocusWithoutSavingTheDraft() async throws {
        let fixture = try EditorFixture()
        defer { fixture.close() }
        await fixture.settle()
        let editor = try fixture.editor()
        editor.insertText("UnsavedDraft", replacementRange: NSRange(location: 0, length: 0))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        await fixture.settle()

        XCTAssertEqual(fixture.focusChanges.last, false)
        XCTAssertFalse(fixture.window.firstResponder === editor)
        XCTAssertTrue(fixture.vocabulary.terms.isEmpty)
        XCTAssertEqual(fixture.viewModel.query, "UnsavedDraft")
    }

    func testBrightnessGlanceDoesNotReplaceFocusedVocabAfterPointerLeaves() {
        XCTAssertFalse(IslandView.brightnessGlanceMayOpen(
            over: .vocabularyEditor, hovering: false, searchFocused: false, vocabularyFocused: true
        ))
        XCTAssertTrue(IslandView.brightnessGlanceMayOpen(
            over: .vocabularyEditor, hovering: false, searchFocused: false, vocabularyFocused: false
        ))
    }

    func testOnlyTheCurrentWindowReleasesEditingFocus() {
        _ = NSApplication.shared
        let first = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let second = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        let editor = IslandVocabularyTextView(frame: .zero)
        var changes: [Bool] = []
        editor.onFocusChange = { changes.append($0) }
        first.contentView = editor
        first.contentView = nil
        second.contentView = editor
        changes.removeAll()

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        XCTAssertTrue(changes.isEmpty)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: second)
        XCTAssertEqual(changes, [false])
        editor.removeWindowObserver()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: second)
        XCTAssertEqual(changes, [false])
    }

    @MainActor
    private final class EditorFixture {
        let suiteName = "test.sidekey.vocab-focus.\(UUID().uuidString)"
        let defaults: UserDefaults
        let vocabulary: VocabularyCache
        let viewModel: IslandVocabularyViewModel
        let window: NSWindow
        var focusChanges: [Bool] = []

        init() throws {
            _ = NSApplication.shared
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            vocabulary = VocabularyCache(defaults: defaults)
            viewModel = IslandVocabularyViewModel(vocabulary: vocabulary)
            window = NSWindow(
                contentRect: CGRect(x: -20_000, y: -20_000, width: 312, height: 145),
                styleMask: [.borderless], backing: .buffered, defer: true
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: IslandVocabularyEditorPanel(
                viewModel: viewModel,
                onFocusChange: { [weak self] in self?.focusChanges.append($0) }
            ))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func settle() async {
            try? await Task.sleep(nanoseconds: 80_000_000)
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func editor() throws -> IslandVocabularyTextView {
            func find(_ view: NSView) -> IslandVocabularyTextView? {
                if let editor = view as? IslandVocabularyTextView { return editor }
                return view.subviews.lazy.compactMap(find).first
            }
            return try XCTUnwrap(window.contentView.flatMap(find))
        }

        func close() {
            window.contentView = nil
            window.close()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func vocabularyEditorSource() throws -> String {
        let root = try projectRoot()
        let url = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("DynamicIsland")
            .appendingPathComponent("IslandVocabularyEditorPanel.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "IslandVocabularyEditorPanelTests", code: 1)
    }
}
