import XCTest
@testable import Sidekey

final class CasePanelFocusRestorationTests: XCTestCase {
    func test_delayed_import_cannot_take_keyboard_from_another_app_on_completion() {
        var policy = CasePanelFocusRestoration()
        XCTAssertFalse(policy.interactionChanged(active: true, isImporting: true))
        // isImporting is cleared by the VM before observers receive completion.
        // The user may now be typing in another application.
        XCTAssertFalse(policy.interactionChanged(active: false, isImporting: false))
    }

    func test_authentication_restores_keyboard_once_and_following_import_does_not() {
        var policy = CasePanelFocusRestoration()
        XCTAssertFalse(policy.interactionChanged(active: true, isImporting: false))
        XCTAssertTrue(policy.interactionChanged(active: false, isImporting: false))
        XCTAssertFalse(policy.interactionChanged(active: false, isImporting: false))
        XCTAssertFalse(policy.interactionChanged(active: true, isImporting: true))
        XCTAssertFalse(policy.interactionChanged(active: false, isImporting: false))
    }
}
