import Darwin
import Foundation
import Security

/// What the broker knows about one process. Signing fields are present only
/// when the running code validates; `teamID` additionally only when an Apple
/// certificate chain vouches for it (see `CaseSystemProcessInspector`).
struct CaseProcessInfo: Equatable {
    let pid: pid_t
    let parentPID: pid_t
    let executablePath: String
    let teamID: String?
    let signingIdentifier: String?
}

/// All process and code-signing syscalls the Case broker makes, behind a seam
/// so caller resolution is testable with a fake process table.
protocol CaseProcessInspecting {
    /// Pid-based lookup: acceptable for ancestors, never for trusting the helper.
    func info(pid: pid_t) -> CaseProcessInfo?
    /// The connected peer of a Unix socket, with its audit token.
    func peer(of socket: Int32) -> (pid: pid_t, auditToken: audit_token_t)?
    /// True when the peer's running code is valid and its cdhash equals the
    /// cdhash of the helper file bundled with this build (works with ad-hoc).
    func isTrustedHelper(auditToken: audit_token_t, helperURL: URL) -> Bool
}

struct CaseSystemProcessInspector: CaseProcessInspecting {
    /// PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a macro Swift does not import.
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    func info(pid: pid_t) -> CaseProcessInfo? {
        // pid 0 is the kernel; it is never an app and is never inspected.
        guard pid > 0 else { return nil }

        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }

        var buffer = [CChar](repeating: 0, count: Self.pathBufferSize)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)

        let signing = Self.signing(pid: pid)
        return CaseProcessInfo(
            pid: pid,
            parentPID: pid_t(bitPattern: bsd.pbi_ppid),
            executablePath: path,
            teamID: signing.teamID,
            signingIdentifier: signing.identifier)
    }

    func peer(of socket: Int32) -> (pid: pid_t, auditToken: audit_token_t)? {
        guard socket >= 0 else { return nil }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              Int(length) == MemoryLayout<audit_token_t>.size
        else { return nil }
        // audit_token_to_pid() lives in libbsm; the pid is the token's 6th word.
        let pid = pid_t(bitPattern: token.val.5)
        guard pid > 0 else { return nil }
        return (pid, token)
    }

    func isTrustedHelper(auditToken: audit_token_t, helperURL: URL) -> Bool {
        // The audit token carries the pid version, so a reused pid cannot
        // stand in for the peer that actually connected.
        var token = auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              let peerHash = Self.cdhash(of: Self.asStatic(code))
        else { return false }

        var helper: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helperURL as CFURL, [], &helper) == errSecSuccess,
              let helper,
              SecStaticCodeCheckValidity(helper, [], nil) == errSecSuccess,
              let helperHash = Self.cdhash(of: helper)
        else { return false }

        return !peerHash.isEmpty && peerHash == helperHash
    }

    // MARK: Private

    /// A SecCode is a SecStaticCode for signing-information queries; passing
    /// the dynamic object makes Security report what the kernel has loaded,
    /// not what is on disk at the path now.
    private static func asStatic(_ code: SecCode) -> SecStaticCode {
        unsafeBitCast(code, to: SecStaticCode.self)
    }

    private static func cdhash(of code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoUnique as String] as? Data
    }

    private static func signing(pid: pid_t) -> (teamID: String?, identifier: String?) {
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess
        else { return (nil, nil) }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            asStatic(code), SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return (nil, nil) }

        let identifier = dict[kSecCodeInfoIdentifier as String] as? String
        let claimedTeam = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let team = claimedTeam.flatMap { appleVouches(for: $0, code: code) ? $0 : nil }
        return (team, identifier)
    }

    /// Any signer can write a team ID into its code directory; only an Apple
    /// chain whose leaf names that team makes it trustworthy.
    private static func appleVouches(for teamID: String, code: SecCode) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard !teamID.isEmpty, teamID.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
