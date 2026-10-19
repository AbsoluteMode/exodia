import XCTest

@MainActor
final class IslandCaseVaultPanelTests: XCTestCase {
    func test_caseVaultPanelUsesSecureValueEntryAndNeverRendersStoredValues() throws {
        let source = try caseVaultPanelSource()

        XCTAssertTrue(source.contains("SecureField"))
        XCTAssertTrue(source.contains("submitValue"))
        XCTAssertTrue(source.contains("copySecret"))
        XCTAssertFalse(source.contains("copyAll"))
        XCTAssertTrue(source.contains("replaceSecret"))
        XCTAssertTrue(source.contains("deleteSecret"))
        XCTAssertFalse(source.contains("CaseSecretValue"))
        XCTAssertFalse(source.contains(".value(for:"))
    }

    func test_caseListResetsDragStateOnBackgroundDropAndDisappearButNotHoverEnd() throws {
        let source = try caseVaultPanelSource()

        let drop = try XCTUnwrap(source.range(of: ".onDrop(of: [UTType.text], isTargeted: nil)"))
        XCTAssertTrue(source[drop.upperBound...].prefix(120).contains("dragState.reset()"))
        let disappear = try XCTUnwrap(source.range(of: ".onDisappear { dragState.reset() }"))
        XCTAssertNotNil(disappear)

        let hover = try XCTUnwrap(source.range(of: ".onContinuousHover"))
        let hoverBody = source[hover.upperBound...].prefix(900)
        let end = try XCTUnwrap(hoverBody.range(of: ".onDrop"))
        XCTAssertFalse(hoverBody[..<end.lowerBound].contains("reset()"))
        XCTAssertFalse(hoverBody[..<end.lowerBound].contains(".ended"))
    }

    func test_caseVaultPanelSupportsGroupsAndDragAutoScroll() throws {
        let source = try caseVaultPanelSource()

        XCTAssertTrue(source.contains("moveSecret"))
        XCTAssertTrue(source.contains("projectSections"))
        XCTAssertTrue(source.contains("dragState.scrollVelocity"))
        XCTAssertTrue(source.contains("UTType.text"))
    }

    func test_caseVaultPanelAutoUnlocksOnOpenAndKeepsRetryWithoutSettingsRoute() throws {
        let source = try caseVaultPanelSource()

        XCTAssertTrue(source.contains("unlockIfNeededOnOpen()"))
        XCTAssertTrue(source.contains("hasTriggeredInitialUnlock"))
        XCTAssertTrue(source.contains("Retry Unlock"))
        XCTAssertTrue(source.contains("Unlocking..."))
        XCTAssertTrue(source.contains("Touch ID"))
        XCTAssertFalse(source.contains("openSettings"))
        XCTAssertFalse(source.contains("Settings"))
    }

    func test_caseVaultPanelArmedResetWarnsAboutPermanentDeletion() throws {
        let source = try caseVaultPanelSource()

        // Two-step confirm: armed state must flip the button label AND swap the
        // supporting copy to spell out that the second press is irreversible.
        XCTAssertTrue(source.contains("Confirm Reset"))
        XCTAssertTrue(source.contains("This permanently deletes this Case. Press again to confirm."))
    }

    private func caseVaultPanelSource() throws -> String {
        let root = try projectRoot()
        let url = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("DynamicIsland")
            .appendingPathComponent("IslandCaseVaultPanel.swift")
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
        throw NSError(domain: "IslandCaseVaultPanelTests", code: 1)
    }
}
