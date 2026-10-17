import AppKit
import XCTest
@testable import Sidekey

final class IslandHoverPanelHitZoneTests: XCTestCase {
    private let compact = CGRect(x: 300, y: 600, width: 310, height: 38)

    func test_drawerAndIslandShareExactEdgesOnEveryDisplayWidth() {
        for width in [CGFloat(310), 312, 360, 500] {
            let pill = CGRect(x: compact.minX, y: compact.minY, width: width, height: compact.height)
            let hover = IslandHoverPanelHitZone(compactFrame: pill, bandHeight: 243)
            XCTAssertEqual(hover.drawerFrame.width, width, accuracy: 0.001)
            XCTAssertEqual(hover.drawerFrame.minX, pill.minX, accuracy: 0.001)
            XCTAssertEqual(hover.drawerFrame.maxX, pill.maxX, accuracy: 0.001)
            XCTAssertEqual(hover.drawerFrame.minY, pill.minY - 243, accuracy: 0.001)
            let frames = [pill] + hover.activeFrames
            for x in [pill.minX + 1, pill.maxX - 1] {
                XCTAssertFalse(IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                    cursor: CGPoint(x: x, y: hover.drawerFrame.midY), activeFrames: frames))
            }
            for x in [pill.minX - 1, pill.maxX + 1] {
                for y in [pill.midY, hover.drawerFrame.midY, hover.transitionFrame.midY] {
                    XCTAssertTrue(IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                        cursor: CGPoint(x: x, y: y), activeFrames: frames),
                        "Hover must not claim space outside the island's horizontal edges.")
                }
            }
        }
    }

    func test_musicTransitionRemainsCompactWidthAndDrawerKeepsItsHeight() {
        let noMusic = IslandHoverPanelHitZone(compactFrame: compact, bandHeight: 267)
        let music = IslandHoverPanelHitZone(compactFrame: compact, bandHeight: 317, musicStripActive: true)
        XCTAssertEqual(music.drawerFrame.height, noMusic.drawerFrame.height, accuracy: 0.001)
        XCTAssertEqual(music.transitionFrame.width, compact.width, accuracy: 0.001)
        XCTAssertEqual(music.transitionFrame.height, 58, accuracy: 0.001)
        let blankCorner = CGPoint(x: music.drawerFrame.minX - 1, y: music.transitionFrame.midY)
        XCTAssertTrue(IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
            cursor: blankCorner, activeFrames: [compact] + music.activeFrames))
        XCTAssertFalse(IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
            cursor: CGPoint(x: compact.midX, y: music.transitionFrame.midY),
            activeFrames: [compact] + music.activeFrames))
    }

    func test_matchingFramesAreGatedByExpansionAndIdleVisibility() {
        let hover = IslandHoverPanelHitZone(compactFrame: compact, bandHeight: 267)
        func frames(expanded: Bool, hidden: Bool) -> [NSRect] {
            IslandPanelMouseEventPolicy.activeFrames(compactFrame: compact, expandedFrame: hover.expandedFrame,
                leftNotificationFrame: .zero, musicStripFrame: .zero, agentSurfaceFrames: [],
                idleHidden: hidden, expanded: expanded, notificationActive: false, musicStripActive: false,
                hoverFrames: hover.activeFrames)
        }
        let capsule = CGPoint(x: hover.drawerFrame.maxX - 1, y: hover.drawerFrame.midY)
        XCTAssertTrue(IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(cursor: capsule,
            activeFrames: frames(expanded: false, hidden: false)))
        XCTAssertFalse(IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(cursor: capsule,
            activeFrames: frames(expanded: true, hidden: false)))
        XCTAssertTrue(IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(cursor: capsule,
            activeFrames: frames(expanded: true, hidden: true)))
    }

    func test_existingReservedAgentWindowContainsMatchingDrawerAndAllModes() {
        let host = CGRect(x: compact.minX - IslandFrameLayout.leftNotificationWidth,
                          y: compact.minY - IslandDropModeControl.hoverPanelHeight
                            - IslandFrameLayout.agentWingGap - IslandFrameLayout.agentAnswerZoneHeight,
                          width: compact.width + IslandFrameLayout.leftNotificationWidth
                            + IslandFrameLayout.rightAgentZoneWidth,
                          height: compact.height + IslandDropModeControl.hoverPanelHeight
                            + IslandFrameLayout.agentWingGap + IslandFrameLayout.agentAnswerZoneHeight)
        for height in [CGFloat(179), 267, 355, 443, 493] {
            let hover = IslandHoverPanelHitZone(compactFrame: compact, bandHeight: height)
            XCTAssertTrue(host.contains(hover.drawerFrame), "Mode height: \(height)")
        }
    }

    func test_historyPreviewCapacityKeepsRightAndTopEdgesFixed() {
        for compactWidth in [CGFloat(310), 312, 500] {
            let pill = CGRect(x: 500, y: 600, width: compactWidth, height: 38)
            let original = reservedHost(for: pill)
            let extended = IslandPanelFramePolicy.reservingHoverPreview(in: original, compactFrame: pill)
            let overhang = IslandHoverPanelHitZone.leftOverhang(compactWidth: compactWidth)
            XCTAssertEqual(extended.minX, original.minX - overhang, accuracy: 0.001)
            XCTAssertEqual(extended.maxX, original.maxX, accuracy: 0.001)
            XCTAssertEqual(extended.minY, original.minY, accuracy: 0.001)
            XCTAssertEqual(extended.maxY, original.maxY, accuracy: 0.001)
            let previewMinX = pill.minX - overhang - 8 - HistoryHoverPreviewPolicy.bubbleWidth
            XCTAssertGreaterThanOrEqual(previewMinX, extended.minX)
            XCTAssertEqual(previewMinX - extended.minX, 12, accuracy: 0.001)
            XCTAssertEqual(IslandPanelFramePolicy.reservingHoverPreview(in: extended, compactFrame: pill),
                           extended, "Capacity reservation must be idempotent.")
        }
    }

    func test_hostExtensionAndMatchingSwiftUIWidthPreservePillAndNotificationPosition() {
        let original = reservedHost(for: compact)
        let extended = IslandPanelFramePolicy.reservingHoverPreview(in: original, compactFrame: compact)
        for agentActive in [false, true] {
            let agentWidth = agentActive ? IslandFrameLayout.rightAgentZoneWidth : 0
            // IslandView has a top-leading root and a trailing-aligned row.
            // Its matching left reservation cancels the native origin shift.
            let oldOuterWidth = compact.width + IslandFrameLayout.leftNotificationWidth + agentWidth
            let newOuterWidth = compact.width
                + IslandHoverPanelHitZone.leftHostReservation(compactWidth: compact.width) + agentWidth
            let oldPillMinX = original.minX + oldOuterWidth - agentWidth - compact.width
            let newPillMinX = extended.minX + newOuterWidth - agentWidth - compact.width
            XCTAssertEqual(oldPillMinX, compact.minX, accuracy: 0.001)
            XCTAssertEqual(newPillMinX, oldPillMinX, accuracy: 0.001)
            XCTAssertEqual(newPillMinX - IslandFrameLayout.leftNotificationWidth,
                           oldPillMinX - IslandFrameLayout.leftNotificationWidth, accuracy: 0.001)
        }
    }

    func test_hostExtensionPreservesMusicAgentAndDrawerScreenCoordinates() {
        let original = reservedHost(for: compact)
        let extended = IslandPanelFramePolicy.reservingHoverPreview(in: original, compactFrame: compact)
        func screenRect(_ boundsRect: CGRect, in host: CGRect) -> CGRect {
            boundsRect.offsetBy(dx: host.minX, dy: host.minY)
        }
        func anchoredRects(in host: CGRect) -> [CGRect] {
            let agent = IslandAgentHitZones(boundsSize: host.size, compactSize: compact.size,
                rightAgentZoneWidth: IslandFrameLayout.rightAgentZoneWidth, wingWidth: 80,
                wingGap: IslandFrameLayout.agentWingGap, answerSize: CGSize(width: 310, height: 120))
            let music = IslandMusicStripHitZone(boundsSize: host.size, compactSize: compact.size,
                rightAgentZoneWidth: IslandFrameLayout.rightAgentZoneWidth,
                topGap: IslandDropModeControl.musicStripTopGap,
                stripHeight: IslandDropModeControl.musicStripHeight)
            let localCompact = CGRect(x: host.width - IslandFrameLayout.rightAgentZoneWidth - compact.width,
                                      y: host.height - compact.height,
                                      width: compact.width, height: compact.height)
            let hover = IslandHoverPanelHitZone(compactFrame: localCompact, bandHeight: 267)
            return [agent.wingRect, agent.answerRect, agent.answerCloseHotspot,
                    music.stripRect, hover.drawerFrame, hover.transitionFrame]
                .map { screenRect($0, in: host) }
        }
        XCTAssertEqual(anchoredRects(in: extended), anchoredRects(in: original))
        let hover = IslandHoverPanelHitZone(compactFrame: compact, bandHeight: 267)
        let previewPoint = CGPoint(x: extended.minX + 1, y: hover.drawerFrame.midY)
        XCTAssertTrue(IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(cursor: previewPoint,
            activeFrames: [compact] + hover.activeFrames),
            "Extra visual capacity must stay click-through; the History preview is non-interactive.")
    }

    private func reservedHost(for pill: CGRect) -> CGRect {
        let below = IslandDropModeControl.hoverPanelHeight
            + IslandFrameLayout.agentWingGap + IslandFrameLayout.agentAnswerZoneHeight
        return CGRect(x: pill.minX - IslandFrameLayout.leftNotificationWidth,
                      y: pill.minY - below,
                      width: pill.width + IslandFrameLayout.leftNotificationWidth
                        + IslandFrameLayout.rightAgentZoneWidth,
                      height: pill.height + below)
    }
}
