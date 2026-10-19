import XCTest
@testable import Sidekey

final class ConfigBackupRegistryTests: XCTestCase {
    func testOnlySelectedBlockIsRestoredAndItsAbsentValuesReturnToDefaults() throws {
        let suite = "ConfigBackupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("deepgram", forKey: "sidekey.models.byokProvider")
        defaults.set("stale-model", forKey: "sidekey.models.openRouterModel")
        defaults.set(false, forKey: "com.sidekey.volumeduck.enabled")
        defaults.set("keep", forKey: "SUFeedURL")
        try ConfigBackupRegistry.apply(["sidekey.models.byokProvider": .string("soniox")], sections: [.models], to: defaults)
        XCTAssertEqual(defaults.string(forKey: "sidekey.models.byokProvider"), "soniox")
        XCTAssertNil(defaults.object(forKey: "sidekey.models.openRouterModel"))
        XCTAssertEqual(defaults.object(forKey: "com.sidekey.volumeduck.enabled") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "SUFeedURL"), "keep")
    }

    func testUnknownPreferencesCredentialAccountsAndWrongTypesRejectBeforeMutation() throws {
        XCTAssertThrowsError(try ConfigBackupRegistry.validate(["SUFeedURL": .string("https://example.com")]))
        XCTAssertThrowsError(try ConfigBackupRegistry.validate(["sidekey.models.byokProvider": .bool(true)]))
        XCTAssertThrowsError(try ConfigBackupRegistry.validate([:], credentials: ["arbitrary.secret": "synthetic"]))
        let suite = "ConfigBackupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("soniox", forKey: "sidekey.models.byokProvider")
        XCTAssertThrowsError(try ConfigBackupRegistry.apply(["SUFeedURL": .string("bad")], sections: [.models], to: defaults))
        XCTAssertEqual(defaults.string(forKey: "sidekey.models.byokProvider"), "soniox")
    }

    func testCaptureExcludesBookmarksUpdaterStateAndUnrelatedSecrets() throws {
        let suite = "ConfigBackupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "com.sidekey.volumeduck.enabled")
        defaults.set("synthetic", forKey: "unrelated.api_key")
        defaults.set(Data([1, 2]), forKey: "configBackup.folderBookmark")
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        XCTAssertEqual(try ConfigBackupRegistry.capture(defaults), ["com.sidekey.volumeduck.enabled": .bool(true)])
    }
    func testCurrentMeetingLanguageAndBrightnessPreferenceTypesArePreserved() throws {
        let suite = "ConfigBackupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ru", forKey: "com.sidekey.meetings.preferredLanguage")
        defaults.set(true, forKey: "sidekey.preferences.brightnessKeys")
        let captured = try ConfigBackupRegistry.capture(defaults)
        XCTAssertEqual(captured["com.sidekey.meetings.preferredLanguage"], .string("ru"))
        XCTAssertEqual(captured["sidekey.preferences.brightnessKeys"], .bool(true))
        try ConfigBackupRegistry.apply(captured, sections: [.models], to: defaults)
        XCTAssertEqual(defaults.string(forKey: "com.sidekey.meetings.preferredLanguage"), "ru")
    }

}
