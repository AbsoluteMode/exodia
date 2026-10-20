import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Offscreen renders of the unlocked Case panel (variant C). The window sits at
/// -20 000 pt and is never ordered front: no visible or key windows.
@MainActor
final class IslandCaseVaultPanelLayoutTests: XCTestCase {
    private let serversID = UUID()
    private let terraID = UUID()

    func test_actual_case_height_exposes_several_keys_without_overflow() async throws {
        let height = IslandCaseVaultStyle.panelHeight
        XCTAssertEqual(IslandView.hoverPanelHeight(for: .caseVault, musicActive: false),
                       IslandDropModeControl.detachedPanelGap + height)
        for width in [CGFloat(310), CGFloat(390)] {
            let fixture = try await PanelFixture(payload: samplePayload(), width: width, height: height)
            defer { fixture.close() }
            fixture.viewModel.expandedProjectIDs.insert(serversID)
            fixture.settle()
            try fixture.saveImage("case-panel-\(Int(width))-320")
            XCTAssertFalse(fixture.isWindowVisible)
        }
    }

    func test_general_section_first_and_expanded() async throws {
        let fixture = try await PanelFixture(payload: samplePayload())
        defer { fixture.close() }
        let viewModel = fixture.viewModel

        let sections = viewModel.projectSections
        XCTAssertEqual(sections.map(\.name), ["General", "servers", "terra-hiring"],
                       "General first, then the other projects by name")
        XCTAssertEqual(sections.map(\.keyCount), [2, 2, 1])
        XCTAssertEqual(sections[0].secrets.map(\.displayName), ["OPENAI_API_KEY", "OPENROUTER_API_KEY"])

        XCTAssertTrue(IslandCaseVaultPanel.isExpanded(sections[0], expandedIDs: viewModel.expandedProjectIDs, isSearching: false),
                      "General is expanded by default")
        XCTAssertFalse(IslandCaseVaultPanel.isExpanded(sections[1], expandedIDs: viewModel.expandedProjectIDs, isSearching: false),
                       "Other projects start collapsed")
        XCTAssertEqual(IslandCaseAddKeyRow.title(projectName: "General"), "+ Ключ в General")

        try fixture.saveImage("case-panel-default")
        XCTAssertFalse(fixture.isWindowVisible)
    }

    func test_search_spans_every_project_and_expands_matches() async throws {
        let fixture = try await PanelFixture(payload: samplePayload())
        defer { fixture.close() }
        let viewModel = fixture.viewModel

        viewModel.query = "netcup"
        XCTAssertTrue(viewModel.isSearching)
        let sections = viewModel.projectSections
        XCTAssertEqual(sections.map(\.name), ["servers"])
        XCTAssertEqual(Set(sections[0].secrets.map(\.displayName)), ["NETCUP_IP", "NETCUP_PASSWORD"])
        XCTAssertEqual(sections[0].keyCount, 2)
        XCTAssertTrue(IslandCaseVaultPanel.isExpanded(sections[0], expandedIDs: viewModel.expandedProjectIDs, isSearching: true))
    }

    func test_no_copy_all_control() throws {
        let identifiers = IslandCaseSecretRow.actions.map(\.accessibilityIdentifier)
            + IslandCaseProjectRow.actions(isGeneral: false).map(\.accessibilityIdentifier)
        XCTAssertFalse(identifiers.contains { $0.lowercased().contains("all") })

        let sources = try panelSources()
        XCTAssertFalse(sources.isEmpty)
        XCTAssertFalse(sources.contains("copyAll"))
        XCTAssertFalse(sources.localizedCaseInsensitiveContains("Copy all"))
        XCTAssertFalse(sources.localizedCaseInsensitiveContains("Скопировать все"))
    }

    func test_general_header_has_no_delete() {
        XCTAssertEqual(IslandCaseProjectRow.actions(isGeneral: true).map(\.accessibilityIdentifier),
                       ["case.project.edit"])
        XCTAssertEqual(IslandCaseProjectRow.actions(isGeneral: false).map(\.accessibilityIdentifier),
                       ["case.project.edit", "case.project.delete"])
        XCTAssertEqual(IslandCaseProjectRow.actions(isGeneral: false).map(\.systemImage), ["pencil", "trash"])
    }

    func test_secret_row_has_edit_copy_delete_in_that_order() {
        XCTAssertEqual(IslandCaseSecretRow.actions.map(\.accessibilityIdentifier),
                       ["case.secret.edit", "case.secret.copy", "case.secret.delete"])
        XCTAssertEqual(IslandCaseSecretRow.actions.map(\.systemImage), ["pencil", "doc.on.doc", "trash"])
    }

    func test_project_delete_confirmation_names_project_and_key_count() {
        XCTAssertEqual(IslandCaseProjectRow.deleteConfirmation(name: "servers", keyCount: 8),
                       "Удалить проект servers и 8 ключей?")
        XCTAssertEqual(IslandCaseProjectRow.deleteConfirmation(name: "servers", keyCount: 1),
                       "Удалить проект servers и 1 ключ?")
        XCTAssertEqual(IslandCaseProjectRow.deleteConfirmation(name: "servers", keyCount: 3),
                       "Удалить проект servers и 3 ключа?")
        XCTAssertEqual(IslandCaseProjectRow.deleteConfirmation(name: "servers", keyCount: 12),
                       "Удалить проект servers и 12 ключей?")
        XCTAssertEqual(IslandCaseProjectRow.deleteConfirmation(name: "servers", keyCount: 21),
                       "Удалить проект servers и 21 ключ?")
    }

    func test_access_row_opens_the_access_screen() throws {
        XCTAssertTrue(IslandCaseVaultPanel.isAccessScreenAvailable)
        let sources = try panelSources()
        XCTAssertTrue(sources.contains("IslandCaseConnectedApps"))
        XCTAssertEqual(IslandCaseConnectedApps.brandAsset(for: CaseKnownClient.claudeCode.identity), "claude-code")
        XCTAssertEqual(IslandCaseConnectedApps.brandAsset(for: CaseKnownClient.codex.identity), "codex")
    }

    func test_renders_at_310pt_without_horizontal_overflow() async throws {
        let width: CGFloat = 310
        // Control: the measurement does report a row that cannot fit.
        XCTAssertGreaterThan(measuredWidth(HStack(spacing: 0) { Color.red.frame(width: 400, height: 10) }, width: width), width)

        let longProject = String(repeating: "p", count: CaseProject.maxNameCharacters)
        let longKey = "K" + String(repeating: "_LONG", count: 12) + "_NAME"
        let longDescription = String(repeating: "очень длинное описание ", count: 6)
        let general = CaseProjectSection(id: CaseProject.generalID, name: "General", description: "", keyCount: 120, secrets: [])
        let long = CaseProjectSection(id: UUID(), name: longProject, description: longDescription, keyCount: 999, secrets: [])
        let secretRow = CaseDisplayRow(id: UUID(), kind: .secret, displayName: longKey, description: longDescription, projectID: long.id)

        let candidates: [(String, AnyView)] = [
            ("general header", AnyView(IslandCaseProjectRow(section: general, isExpanded: true, isDropTargeted: false,
                                                            onToggle: {}, onEdit: {}, onDelete: {}))),
            ("long header", AnyView(IslandCaseProjectRow(section: long, isExpanded: false, isDropTargeted: true,
                                                         onToggle: {}, onEdit: {}, onDelete: {}))),
            ("secret row", AnyView(IslandCaseSecretRow(row: secretRow, onEdit: {}, onCopy: {}, onDelete: {}))),
            ("short value row", AnyView(IslandCaseSecretRow(
                row: CaseDisplayRow(id: UUID(), kind: .secret, displayName: longKey, description: longDescription,
                                    projectID: long.id, valueNotMasked: true),
                onEdit: {}, onCopy: {}, onDelete: {}))),
            ("add key row", AnyView(IslandCaseAddKeyRow(projectName: longProject, action: {}))),
            ("delete confirmation", AnyView(IslandCaseProjectDeleteConfirmation(name: longProject, keyCount: 999,
                                                                               onConfirm: {}, onCancel: {}))),
        ]
        for (name, view) in candidates {
            XCTAssertLessThanOrEqual(measuredWidth(view, width: width), width, "\(name) overflows \(width) pt")
        }

        let payload = samplePayload(extraProjectName: longProject, extraKeyName: longKey)
        let fixture = try await PanelFixture(payload: payload, width: width)
        defer { fixture.close() }
        fixture.viewModel.expandedProjectIDs.insert(serversID)
        fixture.settle()
        XCTAssertLessThanOrEqual(measuredWidth(IslandCaseVaultPanel(viewModel: fixture.viewModel), width: width), width)
        try fixture.saveImage("case-panel-310-long")
        XCTAssertFalse(fixture.isWindowVisible)
    }

    private func measuredWidth<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: view.environment(\.colorScheme, .dark))
        return controller.sizeThatFits(in: CGSize(width: width, height: 2_000)).width
    }

    // MARK: - Fixtures

    private func samplePayload(extraProjectName: String? = nil, extraKeyName: String? = nil) -> CaseVaultPayload {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var projects = [
            CaseProject.general(now: date),
            CaseProject(id: terraID, name: "terra-hiring", description: "", createdAt: date, updatedAt: date),
            CaseProject(id: serversID, name: "servers", description: "Netcup и VPN", createdAt: date, updatedAt: date),
        ]
        var secrets = [
            secret("OPENAI_API_KEY", CaseProject.generalID, date, description: "Личный ключ"),
            secret("OPENROUTER_API_KEY", CaseProject.generalID, date),
            secret("NETCUP_IP", serversID, date),
            secret("NETCUP_PASSWORD", serversID, date),
            secret("POSTGRES_PASSWORD", terraID, date),
        ]
        if let extraProjectName {
            projects.append(CaseProject(id: UUID(), name: extraProjectName, description: "", createdAt: date, updatedAt: date))
        }
        if let extraKeyName {
            secrets.append(secret(extraKeyName, serversID, date,
                                  description: String(repeating: "очень длинное описание ", count: 6)))
        }
        return CaseVaultPayload(
            projects: projects,
            secrets: secrets,
            values: secrets.map { CaseSecretValue(secretID: $0.id, value: "fixture") },
            apps: [CaseKnownClient.claudeCode, .codex].map {
                CaseAppRegistration(id: UUID(), displayName: $0.displayName, identity: $0.identity,
                                    defaultMode: .approve, projectModes: [:], createdAt: date)
            }
        )
    }

    private func secret(_ name: String, _ projectID: UUID, _ date: Date, description: String = "") -> CaseSecret {
        CaseSecret(id: UUID(), name: name, projectID: projectID, description: description,
                   copyCount: 0, lastCopiedAt: nil, createdAt: date, updatedAt: date)
    }

    private func panelSources() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        let directory = url.appendingPathComponent("Sources/Sidekey/DynamicIsland")
        return try ["IslandCaseVaultPanel.swift", "IslandCaseProjectRow.swift", "IslandCaseSecretRow.swift"]
            .map { name -> String in
                let file = directory.appendingPathComponent(name)
                return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            }
            .joined(separator: "\n")
    }
}

@MainActor
private final class PanelFixture {
    let viewModel: CaseViewModel
    let window: NSWindow
    let host: NSHostingView<AnyView>
    private let service: CaseVaultService

    init(payload: CaseVaultPayload, width: CGFloat = 310, height: CGFloat = 480) async throws {
        _ = NSApplication.shared
        var sourceRoot = URL(fileURLWithPath: #filePath)
        while sourceRoot.path != "/", !FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("Package.swift").path) {
            sourceRoot.deleteLastPathComponent()
        }
        ProviderBrandIconAsset.setResourceDirectoryForTesting(sourceRoot.appendingPathComponent("Resources/UsefulLinkIcons"))
        service = CaseVaultService(store: LayoutStubStore(payload: payload), keyProvider: LayoutStubKeys())
        viewModel = CaseViewModel(
            service: service,
            authenticator: LayoutStubAuthenticator(),
            pasteboard: LayoutStubPasteboard(),
            scheduleIdleLock: { _, _ in LayoutStubCancellable() }
        )
        try await viewModel.unlock()

        window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        let modelForRendering = viewModel
        host = NSHostingView(rootView: AnyView(
            IslandCaseVaultPanel(viewModel: modelForRendering)
                .frame(width: width, height: height)
                .background(Color(white: 0.08))
                .environment(\.colorScheme, .dark)
        ))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        settle()
    }

    var isWindowVisible: Bool { window.isVisible || window.isKeyWindow }

    func settle(_ seconds: TimeInterval = 0.15) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        host.layoutSubtreeIfNeeded()
    }

    func saveImage(_ name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_CASE_PROOF_DIR"] else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    func close() {
        window.contentView = nil
        window.close()
        ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
        ProviderBrandIconAsset.clearCacheForTesting()
    }
}

private final class LayoutStubStore: CaseVaultStoring {
    var payload: CaseVaultPayload
    init(payload: CaseVaultPayload) { self.payload = payload }
    func load(using key: SymmetricKey) throws -> CaseVaultPayload { payload }
    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws { self.payload = payload }
    func reset() throws {}
}

private final class LayoutStubKeys: CaseVaultKeyProviding {
    func readOrCreateKey() throws -> SymmetricKey { SymmetricKey(size: .bits256) }
}

private struct LayoutStubAuthenticator: CaseAuthenticating {
    func authenticate(reason: String) async throws {}
}

private final class LayoutStubPasteboard: CasePasteboardWriting {
    func writeString(_ value: String) {}
}

private final class LayoutStubCancellable: CaseIdleLockCancellable {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}
