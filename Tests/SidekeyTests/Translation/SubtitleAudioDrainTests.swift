import Foundation
import XCTest
@testable import Sidekey

private final class TerminalStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var returned: Bool { lock.withLock { storage } }
    func complete() { lock.withLock { storage = true } }
}

final class SubtitleAudioDrainTests: XCTestCase {
    func testTerminalEOFDrainsInflightConversionAndBufferedSourceFrames() async {
        let source = FixtureSubtitleAudio()
        let entered = expectation(description: "First conversion in flight")
        let release = DispatchSemaphore(value: 0)
        let relay = SubtitleAudioRelay(source: source, convert: { samples in
            if samples == [0.1] {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return SubtitleSegmenter.pcm16(samples)
        }, onOverflow: { XCTFail("Three frames must fit") })
        defer { release.signal(); relay.cancel() }
        let consumer = Task { () throws -> [Data] in
            var frames: [Data] = []
            for try await frame in relay.stream { frames.append(frame) }
            return frames
        }
        let frames: [[Float]] = [[0.1], [0.2], [0.3]]
        for frame in frames { source.pair.continuation.yield(frame) }
        await fulfillment(of: [entered], timeout: 1)
        // Exactly the old failure: one frame inside conversion and two buffered
        // at Stop. Source EOF must not cancel the converter/stream iterator.
        await source.stopAndFinishStreams()
        release.signal()
        do {
            let delivered = try await consumer.value
            XCTAssertEqual(delivered, frames.map(SubtitleSegmenter.pcm16))
        } catch { XCTFail("Unexpected audio relay failure") }
    }

    func testCoreAudioTerminalEOFWaitsForIOQueueAndRejectsLaterStart() async {
        let queue = DispatchQueue(label: "test.subtitle.capture")
        let buffers = SystemAudioBufferBroadcast()
        let source = CoreAudioSystemAudioSource(ioQueue: queue, buffers: buffers)
        let stream = source.audioBufferStream()
        let entered = expectation(description: "IO callback entered")
        let started = expectation(description: "Terminal stop started")
        let flag = TerminalStopFlag()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        queue.async {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            buffers.yield([0.1])
        }
        queue.async { buffers.yield([0.2]) }
        await fulfillment(of: [entered], timeout: 1)
        let terminal = Task {
            started.fulfill()
            await source.stopAndFinishStreams()
            flag.complete()
        }
        await fulfillment(of: [started], timeout: 1)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(flag.returned, "EOF must wait for the in-flight IO callback")
        release.signal()
        await terminal.value
        var frames: [[Float]] = []
        for await frame in stream { frames.append(frame) }
        XCTAssertEqual(frames, [[0.1], [0.2]])
        var later = source.audioBufferStream().makeAsyncIterator()
        let afterEOF = await later.next()
        XCTAssertNil(afterEOF)
        do { try await source.start(); XCTFail("Terminal source must not restart capture") }
        catch { XCTAssertTrue(error is CoreAudioSystemAudioSource.CaptureEnded) }
        await source.stopAndFinishStreams() // Idempotent; no real tap was started.
    }

    func testOrdinaryCoreAudioStopPreservesSubscriptionsForReuse() async {
        let buffers = SystemAudioBufferBroadcast()
        let source = CoreAudioSystemAudioSource(buffers: buffers)
        let original = source.audioBufferStream()
        await source.stop()
        buffers.yield([0.1])
        let second = source.audioBufferStream()
        await source.stop()
        buffers.yield([0.2])
        await source.stopAndFinishStreams()
        var firstFrames: [[Float]] = [], secondFrames: [[Float]] = []
        for await frame in original { firstFrames.append(frame) }
        for await frame in second { secondFrames.append(frame) }
        XCTAssertEqual(firstFrames, [[0.1], [0.2]])
        XCTAssertEqual(secondFrames, [[0.2]])
    }
}
