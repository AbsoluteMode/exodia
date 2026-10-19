import Foundation

/// Shared subscriptions survive reusable capture stops. Only terminal capture
/// shutdown closes them, after every callback already on the IO queue returns.
final class SystemAudioBufferBroadcast: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [UUID: AsyncStream<[Float]>.Continuation] = [:]
    private var finished = false

    func stream() -> AsyncStream<[Float]> {
        let id = UUID()
        let pair = AsyncStream<[Float]>.makeStream()
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            self?.remove(id)
        }
        let closed = lock.withLock {
            if finished { return true }
            sinks[id] = pair.continuation
            return false
        }
        if closed { pair.continuation.finish() }
        return pair.stream
    }

    func yield(_ samples: [Float]) {
        let current = lock.withLock { Array(sinks.values) }
        for sink in current { sink.yield(samples) }
    }

    func finish() {
        let current = lock.withLock {
            finished = true
            let current = Array(sinks.values)
            sinks.removeAll()
            return current
        }
        for sink in current { sink.finish() }
    }

    private func remove(_ id: UUID) {
        lock.withLock { sinks[id] = nil }
    }
}
