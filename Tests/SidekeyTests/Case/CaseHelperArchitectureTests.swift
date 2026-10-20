import Darwin
import Foundation
import XCTest
@testable import Sidekey

/// Real signed code and socket audit identities; no vault, app or client setup.
final class CaseHelperArchitectureTests: XCTestCase {
    func test_native_helper_accepts_exact_signed_code_and_rejects_replacements() throws {
        #if arch(arm64)
        try exerciseTrust(architecture: "arm64")
        #else
        try exerciseTrust(architecture: "x86_64")
        #endif
    }

    func test_rosetta_helper_accepts_exact_signed_code_and_rejects_replacements() throws {
        #if arch(arm64)
        let result = try TrustFixture.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"])
        guard result.status == 0 else { throw XCTSkip("Rosetta is unavailable") }
        try exerciseTrust(architecture: "x86_64")
        #else
        throw XCTSkip("Rosetta requires an Apple Silicon test host")
        #endif
    }

    private func exerciseTrust(architecture: String) throws {
        let fixture = try TrustFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let path = fixture.directory.appendingPathComponent("peer.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return XCTFail("socket failed") }
        defer { close(listener) }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return XCTFail("fixture socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 1) == 0 else {
            return XCTFail("fixture bind/listen failed")
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        child.arguments = ["-" + architecture, fixture.helper.path, path]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&readiness, 1, 5_000) > 0, readiness.revents & Int16(POLLIN) != 0 else {
            return XCTFail("signed fixture did not connect")
        }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return XCTFail("accept failed") }
        defer { close(client) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let inspector = CaseSystemProcessInspector()
        let peer = try XCTUnwrap(inspector.peer(of: client))
        XCTAssertEqual(peer.pid, child.processIdentifier)
        XCTAssertTrue(inspector.isTrustedHelper(auditToken: peer.auditToken, helperURL: fixture.helper), architecture)
        XCTAssertFalse(inspector.isTrustedHelper(auditToken: peer.auditToken, helperURL: fixture.foreign),
                       "another validly signed binary with the same identifier is not the bundled helper")
        for tampered in fixture.tampered {
            XCTAssertFalse(inspector.isTrustedHelper(auditToken: peer.auditToken, helperURL: tampered),
                           "a broken signature in either universal slice must fail closed")
        }
        XCTAssertFalse(inspector.isTrustedHelper(auditToken: peer.auditToken, helperURL: fixture.unsigned))
        XCTAssertFalse(inspector.isTrustedHelper(auditToken: audit_token_t(), helperURL: fixture.helper),
                       "an invalid audit identity must never fall back to static trust")

        let original = fixture.directory.appendingPathComponent("original")
        try FileManager.default.moveItem(at: fixture.helper, to: original)
        try FileManager.default.copyItem(at: fixture.foreign, to: fixture.helper)
        XCTAssertFalse(inspector.isTrustedHelper(auditToken: peer.auditToken, helperURL: fixture.helper),
                       "replacing the reference path must not authorize the old running image")

        var release: UInt8 = 1
        XCTAssertEqual(write(client, &release, 1), 1)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertFalse(inspector.isTrustedHelper(auditToken: peer.auditToken, helperURL: original),
                       "an exited socket peer must not be trusted from its stale audit identity")
    }
}

private struct TrustFixture {
    let directory: URL
    let helper: URL
    let foreign: URL
    let tampered: [URL]
    let unsigned: URL

    init() throws {
        directory = URL(fileURLWithPath: "/tmp/case-trust-" + UUID().uuidString.prefix(8))
        helper = directory.appendingPathComponent("helper")
        foreign = directory.appendingPathComponent("foreign")
        tampered = [directory.appendingPathComponent("tampered-first"), directory.appendingPathComponent("tampered-last")]
        unsigned = directory.appendingPathComponent("unsigned")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let source = directory.appendingPathComponent("client.c")
            try Self.clientSource.write(to: source, atomically: true, encoding: .utf8)
            for (output, failure) in [(helper, "64"), (foreign, "65")] {
                let compile = try Self.run("/usr/bin/xcrun", [
                    "clang", "-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=14.2",
                    "-DFIXTURE_FAILURE=" + failure, source.path, "-o", output.path,
                ])
                guard compile.status == 0 else { throw TrustFixtureError.tool(compile.output) }
                let sign = try Self.run("/usr/bin/codesign", [
                    "--force", "--sign", "-", "--identifier", "local.case.trust-fixture", output.path,
                ])
                guard sign.status == 0 else { throw TrustFixtureError.tool(sign.output) }
            }
            let original = try Data(contentsOf: helper)
            let marker = Data("CASE_TRUST_MARKER".utf8)
            let first = try XCTUnwrap(original.range(of: marker))
            let last = try XCTUnwrap(original.range(of: marker, options: .backwards))
            guard first != last else { throw TrustFixtureError.tool("universal fixture needs two markers") }
            for (output, range) in zip(tampered, [first, last]) {
                var bytes = original
                bytes[range.lowerBound] ^= 1
                try bytes.write(to: output)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
            }
            try FileManager.default.copyItem(at: helper, to: unsigned)
            let remove = try Self.run("/usr/bin/codesign", ["--remove-signature", unsigned.path])
            guard remove.status == 0 else { throw TrustFixtureError.tool(remove.output) }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static let clientSource = #"""
    #include <sys/socket.h>
    #include <sys/un.h>
    #include <unistd.h>
    #include <string.h>
    int main(int argc, char **argv) {
        if (argc != 2) return FIXTURE_FAILURE;
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
        if (strlen(argv[1]) >= sizeof(address.sun_path)) return 66;
        strcpy(address.sun_path, argv[1]);
        if (connect(fd, (struct sockaddr *)&address, sizeof(address))) return 67;
        const char marker[] = "CASE_TRUST_MARKER";
        write(fd, marker, sizeof(marker));
        char release;
        read(fd, &release, 1);
        close(fd);
        return 0;
    }
    """#
}

private enum TrustFixtureError: Error {
    case tool(String)
}
