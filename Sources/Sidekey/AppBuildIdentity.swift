import Foundation

/// Describes the actual bundle, including a developer copy in another checkout.
/// Paths are displayed locally in Settings and conflict dialogs, never logged.
struct AppBuildIdentity: Equatable, Sendable {
    // Keep metadata keys compatible with Exodia builds and the common runtime lease.
    static let instanceLeaseVersionKey = "ExodiaInstanceLeaseVersion"
    static let supportedInstanceLeaseVersion = 1

    let bundleIdentifier: String
    let name: String
    let version: String
    let build: String
    let sourceRevision: String?
    let bundlePath: String
    let instanceLeaseVersion: Int

    init(info: [String: Any], bundleURL: URL) {
        bundleIdentifier = info["CFBundleIdentifier"] as? String ?? ""
        name = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? "Whytap"
        version = info["CFBundleShortVersionString"] as? String ?? "Unknown version"
        build = info["CFBundleVersion"] as? String ?? "Unknown build"
        sourceRevision = info["ExodiaSourceRevision"] as? String
        bundlePath = bundleURL.path
        instanceLeaseVersion = (info[Self.instanceLeaseVersionKey] as? NSNumber)?.intValue ?? 0
    }

    init(bundle: Bundle) {
        self.init(info: bundle.infoDictionary ?? [:], bundleURL: bundle.bundleURL)
    }

    static var current: AppBuildIdentity { AppBuildIdentity(bundle: .main) }

    var channel: String {
        if build == "9999" || version.lowercased().contains("-dev") { return "Development" }
        return bundleIdentifier == "com.rootwise.sidekey.beta" ? "Beta" : "Production"
    }

    var versionDescription: String { "\(version) (\(build))" }
    var summary: String { "\(name) · \(channel) · \(versionDescription)" }
    var settingsTitle: String { "\(name) Settings" }
    var quitActionTitle: String { "Quit \(name)" }
    var shortRevision: String? { sourceRevision.map { String($0.prefix(12)) } }

    var usesInstanceLease: Bool {
        instanceLeaseVersion >= Self.supportedInstanceLeaseVersion
    }
}
