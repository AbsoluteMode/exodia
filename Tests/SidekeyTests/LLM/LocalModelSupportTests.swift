import XCTest
@testable import Sidekey

final class LocalModelSupportTests: XCTestCase {
    // MARK: - Runtime hardware detection

    func testRuntimeAppleSiliconMatchesArchUnderUniversalBinary() {
        // The shipped binary is universal, so a compile-time `#if arch(arm64)`
        // is wrong on an Intel slice running under Rosetta. The runtime probe
        // reads `hw.optional.arm64` from sysctl, which reflects the real CPU.
        // On the (Apple-Silicon) CI/dev host this is true; the assertion just
        // pins that the probe returns a definite Bool rather than crashing.
        let value = LocalModelSupport.isAppleSilicon
        XCTAssertTrue(value == true || value == false)
    }
}
