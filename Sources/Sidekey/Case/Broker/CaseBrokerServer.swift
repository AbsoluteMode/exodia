import Darwin
import Foundation
import WhytapCaseKit

enum CaseBrokerServerError: Error, Equatable {
    case pathTooLong
    /// The socket's folder is a symlink, not a folder, or not ours.
    case unsafeDirectory
    /// Something other than a socket sits at the socket path.
    case pathOccupied
    case socketFailed(Int32)
}

/// Unix-socket front of the Case broker. One request per connection,
/// newline-delimited JSON (`CaseBrokerCodec`). The peer is identified by its
/// audit token, and anything other than this build's bundled helper gets
/// `.denied(.untrustedHelper)` before a byte of its request is read. Reads are
/// bounded in size and time so a stuck client cannot hold the broker; the
/// broker itself runs on the main actor. Nothing about a request is logged.
final class CaseBrokerServer: @unchecked Sendable {
    static let defaultMaxRequestBytes = 64 * 1024
    static let defaultReadTimeout: TimeInterval = 5
    static let maxConcurrentConnections = 32

    private let socketURL: URL
    private let broker: CaseBroker
    private let inspector: CaseProcessInspecting
    private let helperURL: URL
    private let readTimeout: TimeInterval
    private let maxRequestBytes: Int

    private let acceptQueue = DispatchQueue(label: "com.rootwise.sidekey.case-broker.accept")
    private let connectionQueue = DispatchQueue(
        label: "com.rootwise.sidekey.case-broker.connection", attributes: .concurrent)
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var socketInode: ino_t?
    private var activeConnections = 0

    init(
        socketURL: URL,
        broker: CaseBroker,
        inspector: CaseProcessInspecting,
        helperURL: URL,
        readTimeout: TimeInterval = CaseBrokerServer.defaultReadTimeout,
        maxRequestBytes: Int = CaseBrokerServer.defaultMaxRequestBytes
    ) {
        self.socketURL = socketURL
        self.broker = broker
        self.inspector = inspector
        self.helperURL = helperURL
        self.readTimeout = readTimeout
        self.maxRequestBytes = maxRequestBytes
    }

    var isRunning: Bool { lock.withLock { source != nil } }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }

        let path = socketURL.path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw CaseBrokerServerError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, byte) in pathBytes.enumerated() { raw[i] = byte }
            raw[pathBytes.count] = 0
        }

        try prepareDirectory(socketURL.deletingLastPathComponent())
        try removeStaleSocket(at: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CaseBrokerServerError.socketFailed(errno) }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw CaseBrokerServerError.socketFailed(code)
        }
        // The folder is already 0700; the file mode is a second fence.
        var info = stat()
        guard chmod(path, 0o600) == 0, lstat(path, &info) == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw CaseBrokerServerError.socketFailed(code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        readSource.setEventHandler { [weak self] in self?.acceptPending(listener: fd) }
        readSource.setCancelHandler { close(fd) }
        source = readSource
        socketInode = info.st_ino
        readSource.resume()
    }

    func stop() {
        lock.lock()
        let running = source
        let inode = socketInode
        source = nil
        socketInode = nil
        lock.unlock()
        guard let running else { return }
        running.cancel()
        // Remove the path only if it is still the socket this server bound.
        var info = stat()
        if let inode, lstat(socketURL.path, &info) == 0, info.st_ino == inode,
           (info.st_mode & S_IFMT) == S_IFSOCK {
            unlink(socketURL.path)
        }
    }

    deinit { stop() }

    // MARK: Filesystem

    private func prepareDirectory(_ dir: URL) throws {
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(dir.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              chmod(dir.path, 0o700) == 0
        else { throw CaseBrokerServerError.unsafeDirectory }
    }

    private func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw CaseBrokerServerError.pathOccupied }
        unlink(path)
    }

    // MARK: Connections

    private func acceptPending(listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return } // EAGAIN: drained; other errors: try on next event
            let admitted: Bool = lock.withLock {
                guard source != nil, activeConnections < Self.maxConcurrentConnections else { return false }
                activeConnections += 1
                return true
            }
            guard admitted else {
                close(client)
                continue
            }
            connectionQueue.async { [self] in serve(client) }
        }
    }

    private func finish(_ fd: Int32) {
        close(fd)
        lock.withLock { activeConnections -= 1 }
    }

    private func serve(_ fd: Int32) {
        // BSD accept() inherits O_NONBLOCK from the listener; reads here block
        // with a timeout instead.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, SO_SNDTIMEO, readTimeout)

        guard let peer = inspector.peer(of: fd) else {
            finish(fd)
            return
        }
        guard inspector.isTrustedHelper(auditToken: peer.auditToken, helperURL: helperURL) else {
            send(.denied(reason: .untrustedHelper), to: fd)
            finish(fd)
            return
        }
        guard let line = readLine(fd),
              let request = try? CaseBrokerCodec.decodeLine(CaseBrokerRequest.self, from: line)
        else {
            finish(fd)
            return
        }

        let broker = self.broker
        let pid = peer.pid
        Task.detached { [self] in
            let response = await broker.handle(request, peerPID: pid)
            send(response, to: fd)
            finish(fd)
        }
    }

    /// Bytes up to the first newline, or nil on EOF, error, timeout or size limit.
    private func readLine(_ fd: Int32) -> Data? {
        let deadline = Date().addingTimeInterval(readTimeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            setTimeout(fd, SO_RCVTIMEO, remaining)
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return nil }
            if let newline = buffer[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[0..<newline])
                return data.count <= maxRequestBytes ? data : nil
            }
            data.append(contentsOf: buffer[0..<n])
            guard data.count <= maxRequestBytes else { return nil }
        }
    }

    private func send(_ response: CaseBrokerResponse, to fd: Int32) {
        guard let line = try? CaseBrokerCodec.encodeLine(response) else { return }
        line.withUnsafeBytes { raw in
            var sent = 0
            while sent < line.count {
                let n = write(fd, raw.baseAddress! + sent, line.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    private func setTimeout(_ fd: Int32, _ option: Int32, _ seconds: TimeInterval) {
        let clamped = max(seconds, 0.001)
        var tv = timeval(tv_sec: Int(clamped), tv_usec: Int32((clamped - floor(clamped)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}
