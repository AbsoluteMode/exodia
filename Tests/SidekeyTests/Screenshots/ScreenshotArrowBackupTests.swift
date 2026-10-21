import XCTest
@testable import Sidekey

@MainActor
final class ScreenshotArrowBackupTests: XCTestCase {
    func testRestoringIntentionalOldMappingIntoFreshProfileDoesNotRepeatMigration() async throws {
        let source = try ArtifactBackupTestProfile(), target = try ArtifactBackupTestProfile()
        defer { source.tearDown(); target.tearDown() }
        let oldStock = ["up": "pen", "down": "blur", "left": "undo", "right": "copy"]
        source.defaults.set(oldStock, forKey: HotkeyPreferences.screenshotArrowsDefaultsKey)
        let preferences = HotkeyPreferences(defaults: source.defaults)
        XCTAssertEqual(preferences.screenshotArrowBindings, .defaults)
        // A deliberate assignment after the migration is not an old default.
        preferences.screenshotArrowBindings = ScreenshotArrowBindings(saved: oldStock)
        preferences.agentTextShortcut = .combo(.optionD)
        preferences.meetingRecordShortcut = .combo(.optionQ)
        let configuration = preferences.configuration
        let providerKey = "sidekey.models.byokProvider"
        source.defaults.set("soniox", forKey: providerKey)
        target.defaults.set("soniox", forKey: providerKey)
        XCTAssertNil(target.defaults.object(forKey: HotkeyPreferences.screenshotArrowDefaultsVersionKey))

        let captured = try ConfigBackupRegistry.capture(source.defaults)
        XCTAssertEqual(try captured[HotkeyPreferences.screenshotArrowDefaultsVersionKey]?.propertyListValue() as? Int, 2)
        let archive = source.root.appendingPathComponent("screenshot-arrows.exodiabackup")
        let key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment())
            .createArchive(at: archive, key: key, sections: [.settings])
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: archive, key: key, sections: [.settings])
        XCTAssertEqual(try ArtifactBackupEngine.applyPendingRestore(environment: environment)?.state, .applied)

        XCTAssertEqual(target.defaults.integer(forKey: HotkeyPreferences.screenshotArrowDefaultsVersionKey), 2)
        let restored = HotkeyPreferences(defaults: target.defaults)
        XCTAssertEqual(restored.screenshotArrowBindings.saved, oldStock)
        XCTAssertEqual(restored.configuration, configuration, "Restoring arrows must preserve the other saved hotkeys")
        XCTAssertEqual(target.defaults.string(forKey: providerKey), "soniox")
        XCTAssertEqual(source.defaults.string(forKey: providerKey), "soniox")
    }
}
