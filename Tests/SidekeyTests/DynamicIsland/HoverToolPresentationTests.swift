import XCTest
@testable import Sidekey

final class HoverToolPresentationTests: XCTestCase {
    private let russian = AppLanguage(code: "ru", displayName: "Русский", englishName: "Russian")
    private let english = AppLanguage(code: "en", displayName: "English", englishName: "English")

    private func presentation(
        _ tool: HoverTool,
        mode: TranscriptionMode = .smart,
        inputLanguage: AppLanguage? = nil,
        outputLanguage: AppLanguage? = nil,
        recording: Bool = false
    ) -> HoverToolPresentation {
        HoverToolPresentation.resolve(tool: tool, mode: mode, inputLanguage: inputLanguage,
                                      outputLanguage: outputLanguage, meetingRecordingActive: recording)
    }

    func testEveryCatalogToolUsesItsRegisteredNonemptyTitle() {
        for tool in HoverTool.allCases {
            let resolved = presentation(tool)
            XCTAssertEqual(resolved.title, HoverToolRegistry.info(for: tool).title)
            XCTAssertFalse(resolved.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let status = resolved.status { XCTAssertFalse(status.isEmpty) }
        }
    }

    func testDropModeDisplaysTheActualSelectedMode() {
        XCTAssertEqual(presentation(.dropMode, mode: .fast).status, "Fast")
        XCTAssertEqual(presentation(.dropMode, mode: .smart).status, "Smart")
    }

    func testInputLanguageDisplaysAutoOrItsNativeNameInEitherMode() {
        for mode in TranscriptionMode.allCases {
            XCTAssertEqual(presentation(.inputLang, mode: mode).status, "Auto")
            XCTAssertEqual(presentation(.inputLang, mode: mode, inputLanguage: russian).status, "Русский")
            XCTAssertEqual(presentation(.inputLang, mode: mode, inputLanguage: english).status, "English")
        }
    }

    func testFastOutputLanguageExplainsTheModeRequirementEvenWithSavedSelection() {
        XCTAssertEqual(presentation(.outputLang, mode: .fast).status, "Smart only")
        XCTAssertEqual(presentation(.outputLang, mode: .fast, outputLanguage: russian).status, "Smart only")
    }

    func testSmartOutputLanguageDisplaysOffOrTheSelectedNativeName() {
        XCTAssertEqual(presentation(.outputLang).status, "Off")
        XCTAssertEqual(presentation(.outputLang, outputLanguage: russian).status, "Русский")
        XCTAssertEqual(presentation(.outputLang, outputLanguage: english).status, "English")
    }

    func testRecordingStatusUsesTheSuppliedRecordingState() {
        XCTAssertEqual(presentation(.meetingRecord, recording: true).status, "Recording")
        XCTAssertEqual(presentation(.meetingRecord, recording: false).status, "Not recording")
    }

    func testNavigationAndStatelessActionsDoNotInventAnEnabledStatus() {
        let stateless: [HoverTool] = [.clipboard, .vocab, .caseVault, .filler, .hotkeys,
                                     .notes, .monitor, .quit, .settings]
        for tool in stateless {
            for mode in TranscriptionMode.allCases {
                XCTAssertNil(presentation(tool, mode: mode, inputLanguage: russian,
                                          outputLanguage: english, recording: true).status)
            }
        }
    }
}
