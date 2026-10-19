import CryptoKit
import XCTest
@testable import Sidekey

final class ConfigBackupArchiveTests: XCTestCase {
    func testPortableArchiveCanBeOpenedWithRecoveryCodeOnAnotherDevice() throws {
        let key = ConfigBackupArchive.makeKey()
        let snapshot = ConfigBackupSnapshot(reason: "Saved version", preferences: [
            "sidekey.models.byokProvider": .string("soniox"),
            "sidekey.preferences.vocabularyTerms": .strings(["Whytap", "Максим"])
        ], credentials: ["byok.soniox.api_key": "synthetic-test-value"])
        let archive = try ConfigBackupArchive.seal(snapshot, key: key)
        let restoredKey = try ConfigBackupArchive.key(from: ConfigBackupArchive.recoveryCode(for: key))
        XCTAssertEqual(try ConfigBackupArchive.open(archive, key: restoredKey), snapshot)
        let text = String(decoding: archive, as: UTF8.self)
        XCTAssertFalse(text.contains("synthetic-test-value"))
        XCTAssertFalse(text.contains("Максим"))
        XCTAssertFalse(text.contains("soniox"))
    }

    func testWrongKeyAndTamperedCiphertextDoNotReturnAnyContent() throws {
        let key = ConfigBackupArchive.makeKey()
        let snapshot = ConfigBackupSnapshot(reason: "Automatic", preferences: [:])
        let archive = try ConfigBackupArchive.seal(snapshot, key: key)
        XCTAssertThrowsError(try ConfigBackupArchive.open(archive, key: ConfigBackupArchive.makeKey()))
        let envelope = try ConfigBackupArchive.readEnvelope(archive)
        var damaged = envelope.sealed
        damaged[damaged.count / 2] ^= 1
        let tampered = try JSONEncoder().encode(ConfigBackupEnvelope(keyID: envelope.keyID, sealed: damaged))
        XCTAssertThrowsError(try ConfigBackupArchive.open(tampered, key: key))
    }

    func testCodeToleratesFormattingButDetectsTypos() throws {
        let key = ConfigBackupArchive.makeKey()
        let code = try ConfigBackupArchive.recoveryCode(for: key)
        XCTAssertEqual(try ConfigBackupArchive.key(from: code.lowercased().replacingOccurrences(of: "-", with: " \n")), key)
        var typo = code
        typo.replaceSubrange(typo.startIndex...typo.startIndex, with: code.first == "A" ? "B" : "A")
        XCTAssertThrowsError(try ConfigBackupArchive.key(from: typo))
        XCTAssertThrowsError(try ConfigBackupArchive.key(from: "password"))
    }

    func testEverySaveUsesAFreshNonce() throws {
        let key = ConfigBackupArchive.makeKey()
        let snapshot = ConfigBackupSnapshot(reason: "Automatic", preferences: [:])
        XCTAssertNotEqual(try ConfigBackupArchive.seal(snapshot, key: key), try ConfigBackupArchive.seal(snapshot, key: key))
    }

    func testNewerAndOversizedArchivesAreRejected() throws {
        let key = ConfigBackupArchive.makeKey()
        var envelope = try ConfigBackupArchive.readEnvelope(ConfigBackupArchive.seal(
            ConfigBackupSnapshot(reason: "Automatic", preferences: [:]), key: key))
        envelope.version = 2
        XCTAssertThrowsError(try ConfigBackupArchive.open(JSONEncoder().encode(envelope), key: key)) { error in
            XCTAssertEqual(error as? ConfigBackupError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try ConfigBackupArchive.readEnvelope(Data(repeating: 0, count: ConfigBackupArchive.maxBytes + 1)))
    }
}
