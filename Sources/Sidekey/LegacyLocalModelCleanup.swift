import Foundation
import os

/// One-time removal of the on-device model weights (up to a few GB) that
/// releases before the local route's removal downloaded into
/// `~/Library/Application Support/Sidekey`. Only the three folders the retired
/// stores owned are removed; FluidAudio keeps its own cache elsewhere (Silero
/// VAD for the meeting detector) and it is never touched.
///
/// Every flavor shares this path, so the pass runs once per flavor: a later
/// download by an older build that still uses local models survives. A folder
/// that could not be removed keeps the pass pending for the next launch.
///
/// WHY: .project-docs/decisions/2026-10-18-legacy-model-cleanup.md
struct LegacyLocalModelCleanup {
    static let folderNames = ["LocalTranscriptionModels", "LocalLLMModels", "LocalDiarizationModels"]
    static let completedDefaultsKey = "com.sidekey.legacyLocalModelCleanup.completed"

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "legacy-model-cleanup")

    let supportDirectory: URL
    let defaults: UserDefaults

    init(supportDirectory: URL = Self.defaultSupportDirectory(), defaults: UserDefaults = .standard) {
        self.supportDirectory = supportDirectory
        self.defaults = defaults
    }

    /// The root the retired model stores resolved, for every flavor.
    static func defaultSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Sidekey", isDirectory: true)
    }

    func run() {
        guard !defaults.bool(forKey: Self.completedDefaultsKey) else { return }
        var removed = 0
        var failed = 0
        for name in Self.folderNames {
            // A symlinked folder loses only the link: removeItem never follows
            // it. No trailing slash either, which would name the target in
            // POSIX path resolution (Foundation strips it today).
            let folder = supportDirectory.appendingPathComponent(name, isDirectory: false)
            do {
                try FileManager.default.removeItem(at: folder)
                removed += 1
            } catch CocoaError.fileNoSuchFile {
                // Never downloaded, or already gone.
            } catch {
                failed += 1
            }
        }
        os_log("legacy model cleanup removed=%{public}d failed=%{public}d",
               log: Self.log, type: .info, removed, failed)
        if failed == 0 {
            defaults.set(true, forKey: Self.completedDefaultsKey)
        }
    }
}
