import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Offscreen renders of «Доступ приложений». The window sits at -20 000 pt
/// and is never ordered front: no visible or key windows.
@MainActor
final class IslandCaseAccessPanelLayoutTests: XCTestCase {
    private let serversID = UUID()
    private let terraID = UUID()

    func test_access_panel_renders_registrations_at_310pt_without_overflow() async throws {
        let width: CGFloat = 310
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let claudeID = UUID()
        let cursorID = UUID()
        var payload = CaseVaultPayload(projects: [
            CaseProject.general(now: date),
            CaseProject(id: serversID, name: "servers", description: "", createdAt: date, updatedAt: date),
            CaseProject(id: terraID, name: "terra-hiring", description: "", createdAt: date, updatedAt: date),
        ])
        payload.apps = [
            CaseAppRegistration(id: claudeID, displayName: "Claude Code", identity: CaseKnownClient.claudeCode.identity,
                                defaultMode: .approve, projectModes: [serversID: .bypass], createdAt: date),
            CaseAppRegistration(id: UUID(), displayName: "Codex", identity: CaseKnownClient.codex.identity,
                                defaultMode: .approve, projectModes: [:], createdAt: date),
            CaseAppRegistration(id: UUID(), displayName: "OpenCode", identity: .builtInOpenCode,
                                defaultMode: .bypass, projectModes: [:], createdAt: date),
            CaseAppRegistration(id: cursorID, displayName: "Cursor", identity: CaseKnownClient.cursor.identity,
                                defaultMode: .bypass, projectModes: [:], createdAt: date),
        ]
        payload.apps[0].allowedProjectIDs = [serversID]
        payload.timedApprovalMinutes = 25

        let service = CaseVaultService(store: AccessStubStore(payload: payload), keyProvider: AccessStubKeys())
        let viewModel = CaseViewModel(service: service, authenticator: AccessStubAuthenticator(),
                                      pasteboard: AccessStubPasteboard(),
                                      scheduleIdleLock: { _, _ in AccessStubCancellable() },
                                      clients: FakeClientSetup())
        try await viewModel.unlock()

        let panel = IslandCaseAccessPanel(viewModel: viewModel, onBack: {}, appID: claudeID)
        XCTAssertLessThanOrEqual(measuredWidth(panel, width: width), width)

        // Hint only for the shared-terminal editor in Bypass.
        XCTAssertTrue(IslandCaseAccessPanel.showsSharedTerminalHint(app: payload.apps[3], known: .cursor))
        XCTAssertFalse(IslandCaseAccessPanel.showsSharedTerminalHint(app: payload.apps[0], known: .claudeCode))
        var cursorApprove = payload.apps[3]
        cursorApprove.defaultMode = .approve
        XCTAssertFalse(IslandCaseAccessPanel.showsSharedTerminalHint(app: cursorApprove, known: .cursor))
        cursorApprove.projectModes[serversID] = .bypass
        XCTAssertTrue(IslandCaseAccessPanel.showsSharedTerminalHint(app: cursorApprove, known: .cursor))
        let custom = CaseAppRegistration(id: UUID(), displayName: "Zed", identity: .executablePath("/Applications/Zed.app"),
                                         defaultMode: .bypass, projectModes: [:], createdAt: date)
        XCTAssertTrue(IslandCaseAccessPanel.showsSharedTerminalHint(app: custom, known: nil))

        try withBrandAssets {
            for width in [CGFloat(310), CGFloat(390)] {
                for (name, appID) in [("selected", claudeID as UUID?), ("all", payload.apps[1].id as UUID?), ("bypass", cursorID as UUID?), ("connect", nil)] {
                    try renderPanel(IslandCaseAccessPanel(viewModel: viewModel, onBack: {}, appID: appID),
                                    width: width, name: "case-access-\(name)-\(Int(width))")
                }
            }
        }
    }

    private func renderPanel<V: View>(_ panel: V, width: CGFloat, name: String) throws {
        let height = IslandCaseVaultStyle.panelHeight
        XCTAssertLessThanOrEqual(measuredWidth(panel, width: width), width)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(panel.frame(width: width, height: height)
            .background(Color(white: 0.08)).environment(\.colorScheme, .dark)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
        if let output = ProcessInfo.processInfo.environment["EXODIA_CASE_PROOF_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
    }

    func test_picker_ready_and_empty_states_fit_the_native_viewport() throws {
        try withBrandAssets {
            for width in [CGFloat(310), CGFloat(390)] {
                for (name, clients, loading, connected) in [
                    ("both", CaseKnownClient.connectableClients, false, false),
                    ("cursor", [.cursor], false, false),
                    ("opencode", [.builtInOpenCode], false, false),
                    ("empty", [], false, false),
                    ("connected", [], false, true),
                    ("loading", [], true, false),
                ] {
                    try renderPanel(IslandCaseClientPicker(clients: clients, isLoading: loading,
                                                          hasConnectedClients: connected, onChoose: { _ in })
                        .padding(10), width: width, name: "case-picker-\(name)-\(Int(width))")
                }
            }
        }
    }

    func test_client_highlights_render_in_provider_colors() throws {
        try withBrandAssets {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let clients: [CaseKnownClient] = [.builtInOpenCode, .cursor, .codex, .claudeCode]
            let row = HStack(spacing: 30) {
                ForEach(clients, id: \.self) { client in
                    let app = CaseAppRegistration(id: UUID(), displayName: client.displayName, identity: client.identity,
                                                  defaultMode: .approve, projectModes: [:], createdAt: date)
                    VStack(spacing: 8) {
                        CaseConnectedAppIcon(app: app, isHighlighted: true, isFocused: true)
                        Text(client.displayName).font(.system(size: 10)).foregroundStyle(.white)
                    }
                }
            }
            .padding(20)
            try renderPanel(row, width: 310, name: "case-provider-highlights")
        }
    }

    private func withBrandAssets(_ body: () throws -> Void) throws {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            root.deleteLastPathComponent()
        }
        ProviderBrandIconAsset.setResourceDirectoryForTesting(root.appendingPathComponent("Resources/UsefulLinkIcons"))
        defer {
            ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
            ProviderBrandIconAsset.clearCacheForTesting()
        }
        for asset in ["opencode", "cursor"] {
            let image = try XCTUnwrap(ProviderBrandIconAsset.image(named: asset, pointSize: 22))
            XCTAssertEqual(image.size, NSSize(width: 22, height: 22))
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let inkPixels = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
                count + (0..<bitmap.pixelsWide).filter {
                    (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1
                }.count
            }
            XCTAssertGreaterThan(inkPixels, bitmap.pixelsWide * bitmap.pixelsHigh / 10,
                                 "\(asset) must contain visible artwork, not an empty PDF mask")
        }
        try body()
    }

    func test_error_messages_are_user_facing() {
        XCTAssertEqual(IslandCaseAccessPanel.message(for: CaseViewModelError.authenticationFailed),
                       "Touch ID не подтверждён — ничего не изменено")
        XCTAssertEqual(IslandCaseAccessPanel.message(for: CaseViewModelError.invalidMinutes), "Разрешение: от 1 до 240 минут")
    }

    private func measuredWidth<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: view.environment(\.colorScheme, .dark))
        return controller.sizeThatFits(in: CGSize(width: width, height: 2_000)).width
    }
}

private final class AccessStubStore: CaseVaultStoring {
    var payload: CaseVaultPayload
    init(payload: CaseVaultPayload) { self.payload = payload }
    func load(using key: SymmetricKey) throws -> CaseVaultPayload { payload }
    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws { self.payload = payload }
    func reset() throws {}
}

private final class AccessStubKeys: CaseVaultKeyProviding {
    func readOrCreateKey() throws -> SymmetricKey { SymmetricKey(size: .bits256) }
}

private struct AccessStubAuthenticator: CaseAuthenticating {
    func authenticate(reason: String) async throws {}
}

private final class AccessStubPasteboard: CasePasteboardWriting {
    func writeString(_ value: String) {}
}

private final class AccessStubCancellable: CaseIdleLockCancellable {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}
