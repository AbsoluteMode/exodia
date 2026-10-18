import XCTest
@testable import Sidekey

/// The one-time launch cleanup of the retired on-device model folders. It
/// deletes user files, so these tests pin what goes and, just as much, what
/// stays: the rest of Application Support/Sidekey, FluidAudio's own model
/// cache (Silero VAD for the meeting detector) and anything behind a symlink.
/// WHY: .project-docs/decisions/2026-10-18-legacy-model-cleanup.md
final class LegacyLocalModelCleanupTests: XCTestCase {
    /// Stands in for `~/Library/Application Support`.
    private var applicationSupport: URL!
    /// Stands in for `~/Library/Application Support/Sidekey`.
    private var sidekeySupport: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        applicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyLocalModelCleanupTests-\(UUID().uuidString)", isDirectory: true)
        sidekeySupport = applicationSupport.appendingPathComponent("Sidekey", isDirectory: true)
        defaultsSuiteName = "LegacyLocalModelCleanupTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
    }

    override func tearDown() {
        // The retry test makes the Sidekey folder read-only; restore it so the
        // temporary tree can be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sidekeySupport.path)
        try? FileManager.default.removeItem(at: applicationSupport)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        applicationSupport = nil
        sidekeySupport = nil
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testRemovesTheThreeRetiredModelFolders() throws {
        try makeFile("Sidekey/LocalTranscriptionModels/parakeet-tdt-0.6b-v3/Encoder.mlmodelc/weights.bin")
        try makeFile("Sidekey/LocalLLMModels/models/mlx-community/Qwen3-4B-Instruct-2507-4bit/model.safetensors")
        try makeFile("Sidekey/LocalDiarizationModels/segmentation.mlmodelc/weights.bin")

        makeCleanup().run()

        XCTAssertFalse(entryExists("Sidekey/LocalTranscriptionModels"))
        XCTAssertFalse(entryExists("Sidekey/LocalLLMModels"))
        XCTAssertFalse(entryExists("Sidekey/LocalDiarizationModels"))
    }

    func testKeepsTheRestOfApplicationSupportIncludingFluidAudioModels() throws {
        try makeFile("Sidekey/LocalLLMModels/models/mlx-community/Qwen3-4B-Instruct-2507-4bit/model.safetensors")
        try makeFile("Sidekey/Meetings/meetings.sqlite")
        try makeFile("Sidekey/meetings-staging/take/mic.pcm")
        try makeFile("FluidAudio/Models/silero-vad-coreml/silero-vad.mlmodelc/weights.bin")
        try makeFile("FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc/weights.bin")

        makeCleanup().run()

        XCTAssertFalse(entryExists("Sidekey/LocalLLMModels"))
        XCTAssertTrue(entryExists("Sidekey/Meetings/meetings.sqlite"))
        XCTAssertTrue(entryExists("Sidekey/meetings-staging/take/mic.pcm"))
        XCTAssertTrue(entryExists("FluidAudio/Models/silero-vad-coreml/silero-vad.mlmodelc/weights.bin"))
        XCTAssertTrue(entryExists("FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc/weights.bin"))
    }

    func testSymlinkedFolderLosesOnlyTheLink() throws {
        try makeFile("Elsewhere/weights.bin")
        try FileManager.default.createDirectory(at: sidekeySupport, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: url("Sidekey/LocalLLMModels"),
            withDestinationURL: url("Elsewhere")
        )

        makeCleanup().run()

        XCTAssertFalse(entryExists("Sidekey/LocalLLMModels"))
        XCTAssertTrue(entryExists("Elsewhere/weights.bin"))
    }

    func testRunsOnlyOnce() throws {
        try makeFile("Sidekey/LocalLLMModels/models/first.safetensors")
        makeCleanup().run()
        XCTAssertFalse(entryExists("Sidekey/LocalLLMModels"))

        // An older build that shares this folder downloads its model again.
        try makeFile("Sidekey/LocalLLMModels/models/second.safetensors")
        makeCleanup().run()

        XCTAssertTrue(entryExists("Sidekey/LocalLLMModels/models/second.safetensors"))
    }

    func testAbsentFoldersCountAsCleanedUp() throws {
        makeCleanup().run()

        try makeFile("Sidekey/LocalLLMModels/models/later.safetensors")
        makeCleanup().run()

        XCTAssertTrue(entryExists("Sidekey/LocalLLMModels/models/later.safetensors"))
    }

    func testFolderThatCannotBeRemovedIsRetriedOnNextLaunch() throws {
        try makeFile("Sidekey/LocalLLMModels/models/model.safetensors")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sidekeySupport.path)

        makeCleanup().run()
        XCTAssertTrue(entryExists("Sidekey/LocalLLMModels"))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sidekeySupport.path)
        makeCleanup().run()

        XCTAssertFalse(entryExists("Sidekey/LocalLLMModels"))
    }

    // MARK: - Helpers

    private func makeCleanup() -> LegacyLocalModelCleanup {
        LegacyLocalModelCleanup(supportDirectory: sidekeySupport, defaults: defaults)
    }

    private func url(_ relativePath: String) -> URL {
        applicationSupport.appendingPathComponent(relativePath)
    }

    private func makeFile(_ relativePath: String) throws {
        let file = url(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("weights".utf8).write(to: file)
    }

    /// lstat semantics: a symlink is checked by itself, not by its target.
    private func entryExists(_ relativePath: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url(relativePath).path)) != nil
    }
}
