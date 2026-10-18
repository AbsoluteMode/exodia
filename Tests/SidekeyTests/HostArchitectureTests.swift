import XCTest
@testable import Sidekey

final class HostArchitectureTests: XCTestCase {
    // MARK: - Runtime hardware detection

    func testDetectionMatchesMachineNameAndRosettaState() {
        // The shipped binary is universal, so a compile-time `#if arch(arm64)`
        // is wrong on an Intel slice running under Rosetta. The probe reads
        // `hw.optional.arm64`; the oracle below reaches the same answer from
        // other kernel facts, so an inverted or broken probe fails here.
        let expected = Self.hostIsAppleSiliconByMachineName()
        XCTAssertEqual(HostArchitecture.detectAppleSilicon(), expected)
        XCTAssertEqual(HostArchitecture.isAppleSilicon, expected)
    }

    /// A native process on Apple Silicon sees an `arm64` machine name. A
    /// process translated by Rosetta sees `x86_64` there, but
    /// `sysctl.proc_translated` is 1; on Intel that key is 0 or absent.
    private static func hostIsAppleSiliconByMachineName() -> Bool {
        var info = utsname()
        guard uname(&info) == 0 else { return false }
        let machine = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        if machine.hasPrefix("arm64") { return true }
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
    }
}
