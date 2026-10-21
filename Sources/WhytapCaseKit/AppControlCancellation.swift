import Foundation

/// Cancellation owns no descriptor: it only shuts down a currently attached
/// socket. Detaching under the same lock before close prevents descriptor reuse.
public final class AppControlCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var socket: Int32?
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() {
        lock.withLock {
            cancelled = true
            if let socket { shutdown(socket, SHUT_RDWR) }
        }
    }
    func attach(_ descriptor: Int32) {
        lock.withLock {
            socket = descriptor
            if cancelled { shutdown(descriptor, SHUT_RDWR) }
        }
    }
    func detach() { lock.withLock { socket = nil } }
}

public protocol CancellableCaseBrokerCalling: CaseBrokerCalling {
    func send(_ request: CaseBrokerRequest, cancellation: AppControlCancellation?) throws -> CaseBrokerResponse
}
