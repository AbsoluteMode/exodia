import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class BrightnessHoverToolTests: XCTestCase {
    // MARK: Catalog

    func testBrightnessIsAnInlinePanelOfferedOnlyFromTheCatalog() {
        let info = HoverToolRegistry.info(for: .brightness)
        XCTAssertEqual(info.title, "Display")
        XCTAssertEqual(info.kind, .inlinePanel)
        XCTAssertEqual(HoverSlotRouter.effect(for: .brightness), .openPanel(.brightness))
        XCTAssertTrue(HoverSlotRouter.effect(for: .brightness).requiresExpansion)
        XCTAssertFalse(HoverLayoutStore.defaultSlots.contains(.brightness),
                       "Existing layouts do not change; the user adds Brightness from Toolbox or search.")
    }

    func testSearchFindsBrightnessByItsOwnWordsInBothLanguages() {
        for query in ["brightness", "display", "яркость", "vivid", "xdr", "battery", "батарея"] {
            XCTAssertEqual(IslandHoverToolSearch.results(for: query).first, .brightness, query)
        }
    }

    func testCapsuleTitleFitsOneLineOfTheNarrowestCapsule() {
        // 310 pt island: the text column is the capsule minus 6 pt padding on both sides,
        // the icon disk and 5 pt spacing. A longer single word breaks mid-word ("Brightne" / "ss").
        let column = IslandHoverControlsLayout.tileWidth(panelWidth: 310) - 12 - IslandHoverPanelControl.iconSize - 5
        let title = HoverToolRegistry.info(for: .brightness).title
        let width = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        ]).size().width
        XCTAssertLessThanOrEqual(width, column, title)
    }

    func testCapsuleStatusShowsTheLevelOrExtra() {
        func status(_ brightness: HoverBrightnessStatus?) -> String? {
            HoverToolPresentation.resolve(tool: .brightness, mode: .smart, inputLanguage: nil, outputLanguage: nil,
                                          meetingRecordingActive: false, brightness: brightness).status
        }
        XCTAssertEqual(status(.level(0.42)), "42%")
        XCTAssertEqual(status(.level(1.7)), "100%")
        XCTAssertEqual(status(.level(.nan)), "0%")
        XCTAssertEqual(status(.extra), "Extra")
        XCTAssertNil(status(nil), "An unreadable display shows no invented level.")
    }

    // MARK: Island

    func testStripBandIsShortWithAndWithoutMusic() {
        for count in [1, 6, 13] {
            XCTAssertEqual(IslandView.hoverPanelHeight(for: .brightness, musicActive: false, toolCount: count), 76)
            XCTAssertEqual(IslandView.hoverPanelHeight(for: .brightness, musicActive: true, toolCount: count), 126)
        }
        XCTAssertEqual(IslandDropModeControl.detachedPanelGap + IslandBrightnessStrip.contentHeight, 76)
    }

    func testHeldZoneKeepsTheTallerHeightUntilReleased() {
        XCTAssertEqual(IslandView.heldHoverPanelHeight(76, hold: 243), 243)
        XCTAssertEqual(IslandView.heldHoverPanelHeight(76, hold: nil), 76)
        XCTAssertEqual(IslandView.heldHoverPanelHeight(243, hold: 76), 243)
    }

    func testHeldZoneIsTransparentSpaceReleasedOnReachingTheStrip() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Sidekey/DynamicIsland/IslandView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains(".frame(width: compactWidth, height: activeHoverPanelHeight, alignment: .top)"),
                      "The drawer stays top-aligned; the held height extends below it.")
        let release = try XCTUnwrap(source.range(of: ".onContinuousHover { phase in"))
        let releaseBody = source[release.upperBound...].prefix(300)
        XCTAssertTrue(releaseBody.contains("hoverPanelHeightHold = nil"),
                      "Reaching the visible strip releases the held zone.")
    }

    func testStripTakesKeyStatusForItsControls() {
        XCTAssertTrue(IslandHoverPanelMode.brightness.needsKeyboardFocus)
    }

    // MARK: Strip

    func testSliderMapsThePointerFromTheSunToTheEnd() {
        XCTAssertEqual(BrightnessCapsuleSlider.level(atX: 12, width: 200), 0)
        XCTAssertEqual(BrightnessCapsuleSlider.level(atX: 188, width: 200), 1)
        XCTAssertEqual(BrightnessCapsuleSlider.level(atX: 100, width: 200), 0.5)
        XCTAssertEqual(BrightnessCapsuleSlider.level(atX: -10, width: 200), 0)
        XCTAssertEqual(BrightnessCapsuleSlider.level(atX: 300, width: 200), 1)
        XCTAssertEqual(BrightnessCapsuleSlider.level(atX: 10, width: 20), 0)
    }

    func testFillAlwaysCoversTheSun() {
        XCTAssertEqual(BrightnessCapsuleSlider.fillWidth(level: 0, width: 200), 24)
        XCTAssertEqual(BrightnessCapsuleSlider.fillWidth(level: 0.5, width: 200), 112)
        XCTAssertEqual(BrightnessCapsuleSlider.fillWidth(level: 1, width: 200), 200)
        XCTAssertEqual(BrightnessCapsuleSlider.fillWidth(level: 2, width: 200), 200)
    }

    func testEveryStatusLineFitsTheNarrowestIsland() {
        // 310 pt island, 10 pt padding on both sides, 32 pt under the back button.
        let lineWidth: CGFloat = 310 - 20 - 32
        let iconAndSpacing: CGFloat = 19
        let notices = [ScreenBrightnessController.writeFailedNotice,
                       ScreenBrightnessController.extraUnavailableNotice,
                       ScreenBrightnessController.coolingNotice]
        for notice in notices {
            XCTAssertLessThanOrEqual(Self.width(notice, size: 10) + iconAndSpacing, lineWidth, notice)
        }
        XCTAssertLessThanOrEqual(Self.width(IslandBrightnessStrip.unavailableText, size: 11), lineWidth)
        let longest: [BatteryRuntimeStatus] = [
            .remaining(percent: 100, minutes: 1_435), .estimating(percent: 100),
            .unplugged(percent: 100, minutes: 1_435, isCharging: false), .onPower(percent: 100, isCharging: true),
        ]
        for status in longest {
            let text = BatteryRuntimeFormatter.text(for: status) ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertLessThanOrEqual(Self.width(text, size: 11) + iconAndSpacing, lineWidth, text)
        }
    }

    /// The real strip with fake hardware, laid out in an unordered offscreen window.
    func testStripFitsItsBandInEveryState() throws {
        for width in [CGFloat(310), 330] {
            for state in StripState.allCases {
                let fixture = StripFixture(state: state, width: width)
                defer { fixture.close() }
                fixture.settle()
                // Without a status line only the control row and its padding remain.
                let expected: CGFloat = state == .noBattery ? 44 : IslandBrightnessStrip.contentHeight
                XCTAssertEqual(fixture.idealHeight, expected, accuracy: 0.5, "\(state) at \(width) pt")
                try fixture.saveImage("brightness-\(state)-\(Int(width))")
            }
        }
    }

    func testOnlyAShownStripPollsTheDisplayAndBattery() {
        let fixture = StripFixture(state: .extraOff, width: 310)
        defer { fixture.close() }
        fixture.settle()
        XCTAssertTrue(fixture.controller.isPolling)
        XCTAssertTrue(fixture.battery.isSampling)

        fixture.removeStrip()
        XCTAssertFalse(fixture.controller.isPolling)
        XCTAssertFalse(fixture.battery.isSampling)
    }

    private static func width(_ text: String, size: CGFloat) -> CGFloat {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
        ]).size().width
    }
}

private enum StripState: String, CaseIterable {
    case extraOff, extraOn, noExtra, unavailable, notice, onPower, noBattery
}

/// No real backlight, overlay, battery or input events.
@MainActor
private final class StripFixture {
    let controller: ScreenBrightnessController
    let battery: BatteryRuntimeMonitor
    let window: NSWindow
    let host: NSHostingView<AnyView>

    init(state: StripState, width: CGFloat) {
        let device = StaticBrightnessDevice(
            headroom: state == .noExtra ? 1 : 16,
            level: state == .unavailable ? nil : 0.62,
            canWrite: state != .notice)
        controller = ScreenBrightnessController(device: device, selectedDisplayID: { 1 }, observeSystem: false)
        let snapshot: BatterySnapshot? = switch state {
        case .noBattery: nil
        case .onPower: BatterySnapshot(percent: 100, isOnAC: true, isCharging: false)
        default: BatterySnapshot(percent: 84, isOnAC: false, isCharging: false, systemMinutesToEmpty: 260)
        }
        battery = BatteryRuntimeMonitor(read: { snapshot })
        controller.refresh()
        switch state {
        case .extraOn: controller.setExtra(true)
        case .notice: controller.setLevel(0.3)
        default: break
        }

        window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: width,
                                              height: IslandBrightnessStrip.contentHeight),
                          styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        host = NSHostingView(rootView: AnyView(
            IslandBrightnessStrip(controller: controller, battery: battery, onBack: {})
                .frame(width: width)
                .background(Color(white: 0.11))
                .environment(\.colorScheme, .dark)))
        // Default sizing options keep fittingSize at the strip's ideal size (with none it is zero);
        // the drawer gives the strip exactly its content height.
        host.frame = CGRect(x: 0, y: 0, width: width, height: IslandBrightnessStrip.contentHeight)
        window.contentView = host
    }

    /// The strip's own height, independent of the frame the drawer gives it.
    var idealHeight: CGFloat { host.fittingSize.height }

    func settle() {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.06))
        host.layoutSubtreeIfNeeded()
    }

    func removeStrip() {
        host.rootView = AnyView(EmptyView())
        settle()
    }

    func saveImage(_ name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_BRIGHTNESS_PROOF_DIR"] else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    func close() {
        removeStrip()
        controller.shutdown()
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class StaticBrightnessDevice: ScreenBrightnessDevice {
    private let headroom: Double
    private var level: Double?
    private let canWrite: Bool

    init(headroom: Double, level: Double?, canWrite: Bool) {
        self.headroom = headroom
        self.level = level
        self.canWrite = canWrite
    }

    func displays() -> [ScreenBrightnessDisplay] { [ScreenBrightnessDisplay(id: 1, potentialHeadroom: headroom)] }

    func read(_ id: CGDirectDisplayID) -> Double? { level }

    func write(_ next: Double, to id: CGDirectDisplayID) -> Bool {
        guard canWrite, level != nil else { return false }
        level = next
        return true
    }

    func makeOverlay(for id: CGDirectDisplayID, multiplier: Double,
                     onFailure: @escaping () -> Void) -> BrightnessOverlay? { NoOverlay() }
}

@MainActor
private final class NoOverlay: BrightnessOverlay {
    func update(multiplier: Double) {}
    func close() {}
}
