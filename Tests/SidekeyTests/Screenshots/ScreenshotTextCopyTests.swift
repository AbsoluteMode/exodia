import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class ScreenshotTextCopyTests: XCTestCase {
    private enum ReadError: Error { case unavailable }

    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    private func board() throws -> NSPasteboard {
        let board = NSPasteboard(name: .init("ScreenshotTextCopyTests.\(UUID().uuidString)"))
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setString("Previous text", forType: .string)
        first.setData(Data("{\\rtf1 Previous text}".utf8), forType: .rtf)
        second.setData(Data([0, 1, 2, 255]), forType: .init("test.whytap.binary"))
        second.setString("file:///synthetic-fixture.txt", forType: .fileURL)
        XCTAssertTrue(board.writeObjects([first, second]))
        return board
    }

    func testSuccessfulCopyCommitsPlainText() async throws {
        let board = try board(); defer { board.releaseGlobally() }
        let image = try fixture()
        let result = await ScreenshotTextCopy.perform(source: image, size: CGSize(width: 40, height: 20), annotations: [],
            crop: CGRect(x: 0, y: 0, width: 40, height: 20), pasteboard: board,
            recognize: { _ in "Invoice 401\nПривет 123456" }, isCurrent: { true })
        XCTAssertEqual(result, .copied)
        XCTAssertEqual(board.string(forType: .string), "Invoice 401\nПривет 123456")
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertNil(board.data(forType: .rtf))
    }

    func testWriteFailureRestoresAllPreviousItemsAndFormats() async throws {
        let board = try board(); defer { board.releaseGlobally() }
        let previous = Pasteboard.snapshot(of: board), image = try fixture()
        var writes = 0
        let result = await ScreenshotTextCopy.perform(source: image, size: CGSize(width: 40, height: 20), annotations: [],
            crop: CGRect(x: 0, y: 0, width: 40, height: 20), pasteboard: board,
            recognize: { _ in "New text" }, write: { _, target in
                writes += 1
                XCTAssertTrue(target.setString("Partial write", forType: .string))
                return false
            }, isCurrent: { true })
        XCTAssertEqual(result, .failed); XCTAssertEqual(writes, 1)
        XCTAssertEqual(Pasteboard.snapshot(of: board), previous)
    }

    func testFailedWriteDoesNotRestoreOverANewerClipboardOwner() async throws {
        let board = try board(); defer { board.releaseGlobally() }
        let image = try fixture()
        let result = await ScreenshotTextCopy.perform(source: image, size: CGSize(width: 40, height: 20), annotations: [],
            crop: CGRect(x: 0, y: 0, width: 40, height: 20), pasteboard: board,
            recognize: { _ in "Old result" }, write: { _, target in
                target.clearContents()
                XCTAssertTrue(target.setString("Newer owner", forType: .string))
                return false
            }, isCurrent: { true })
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(board.string(forType: .string), "Newer owner")
    }

    func testEmptyAndFailedRecognitionLeaveClipboardUntouched() async throws {
        let board = try board(); defer { board.releaseGlobally() }
        let previous = Pasteboard.snapshot(of: board), count = board.changeCount, image = try fixture()
        for fails in [false, true] {
            var writes = 0
            let result = await ScreenshotTextCopy.perform(source: image, size: CGSize(width: 40, height: 20), annotations: [],
                crop: CGRect(x: 0, y: 0, width: 40, height: 20), pasteboard: board,
                recognize: { _ in if fails { throw ReadError.unavailable }; return " \n\t" },
                write: { _, _ in writes += 1; return true }, isCurrent: { true })
            XCTAssertEqual(result, fails ? .failed : .empty); XCTAssertEqual(writes, 0)
            XCTAssertEqual(board.changeCount, count); XCTAssertEqual(Pasteboard.snapshot(of: board), previous)
        }
    }

    func testCancellationDiscardsARecognizerThatReturnsLate() async throws {
        let board = try board(); defer { board.releaseGlobally() }
        let previous = Pasteboard.snapshot(of: board), count = board.changeCount, image = try fixture()
        let entered = expectation(description: "Recognizer entered"), release = DispatchSemaphore(value: 0)
        let task = Task {
            await ScreenshotTextCopy.perform(source: image, size: CGSize(width: 40, height: 20), annotations: [],
                crop: CGRect(x: 0, y: 0, width: 40, height: 20), pasteboard: board,
                recognize: { _ in
                    entered.fulfill(); release.wait()
                    return "Late cancelled result"
                }, isCurrent: { true })
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel(); release.signal()
        let result = await task.value
        XCTAssertEqual(result, .discarded)
        XCTAssertEqual(board.changeCount, count); XCTAssertEqual(Pasteboard.snapshot(of: board), previous)
    }

    func testNewGenerationDiscardsAResultFromTheOldCapture() async throws {
        let board = try board(); defer { board.releaseGlobally() }
        let image = try fixture(), token = UUID()
        var generation = token
        let entered = expectation(description: "Old recognizer entered"), release = DispatchSemaphore(value: 0)
        let task = Task {
            await ScreenshotTextCopy.perform(source: image, size: CGSize(width: 40, height: 20), annotations: [],
                crop: CGRect(x: 0, y: 0, width: 40, height: 20), pasteboard: board,
                recognize: { _ in
                    entered.fulfill(); release.wait()
                    return "Late old-generation result"
                }, isCurrent: { generation == token })
        }
        await fulfillment(of: [entered], timeout: 2)
        generation = UUID()
        board.clearContents(); XCTAssertTrue(board.setString("New capture clipboard", forType: .string))
        let current = Pasteboard.snapshot(of: board), count = board.changeCount
        release.signal()
        let result = await task.value
        XCTAssertEqual(result, .discarded)
        XCTAssertEqual(board.changeCount, count); XCTAssertEqual(Pasteboard.snapshot(of: board), current)
    }
}
