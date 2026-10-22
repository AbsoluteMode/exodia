import AppKit
import WhytapCaseKit
import XCTest
@testable import Sidekey

@MainActor
final class AgentScreenCaptureTests: XCTestCase {
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        return try XCTUnwrap(context.makeImage())
    }

    func testDeniedAccessAndInvalidArgumentsNeverCapture() async {
        var permissions = 0
        var captures = 0
        let capture = AgentScreenCapture(permission: { permissions += 1; return false }, capture: { _ in
            captures += 1; throw CocoaError(.userCancelled)
        })
        for args: [String: AppControlValue] in [["display_id": .bool(true)], ["display_id": .int(-1)], ["path": .string("/tmp/ignored")]] {
            let reply = await capture.handle(args)
            XCTAssertEqual(reply.data.object?["code"], .string("invalid_arguments"))
        }
        XCTAssertEqual(permissions, 0)
        let denied = await capture.handle([:])
        XCTAssertEqual(denied.data.object?["code"], .string("screen_permission"))
        XCTAssertEqual(permissions, 1)
        XCTAssertEqual(captures, 0)
    }

    func testRequestedDisplayProducesDecodableImageWithoutFilesOrClipboard() async throws {
        let image = try image()
        let capture = AgentScreenCapture(permission: { true }, capture: { display in
            XCTAssertEqual(display, 42); return (42, image)
        })
        let reply = await capture.handle(["display_id": .int(42)])
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.data.object?["width"], .int(32))
        XCTAssertEqual(reply.data.object?["display_id"], .int(42))
        let encoded = try XCTUnwrap(reply.data.object?["image"]?.string)
        let bitmap = try XCTUnwrap(Data(base64Encoded: encoded).flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(bitmap.pixelsWide, 32)
        XCTAssertEqual(bitmap.pixelsHigh, 16)
    }

    func testDeadlineReturnsEvenIfCaptureIgnoresCancellation() async {
        var release: CheckedContinuation<(CGDirectDisplayID, CGImage), Error>?
        let capture = AgentScreenCapture(permission: { true }, timeout: .milliseconds(10), capture: { _ in
            try await withCheckedThrowingContinuation { release = $0 }
        })
        let reply = await capture.handle([:])
        XCTAssertEqual(reply.data.object?["code"], .string("capture_timeout"))
        release?.resume(throwing: CocoaError(.userCancelled))
    }

    func testCancellationAndBusyAreBounded() async {
        var release: CheckedContinuation<(CGDirectDisplayID, CGImage), Error>?
        let capture = AgentScreenCapture(permission: { true }, capture: { _ in
            try await withCheckedThrowingContinuation { release = $0 }
        })
        let task = Task { await capture.handle([:]) }
        while release == nil { await Task.yield() }
        let busy = await capture.handle([:])
        XCTAssertEqual(busy.data.object?["code"], .string("busy"))
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.data.object?["code"], .string("cancelled"))
        release?.resume(throwing: CocoaError(.userCancelled))
    }
}
