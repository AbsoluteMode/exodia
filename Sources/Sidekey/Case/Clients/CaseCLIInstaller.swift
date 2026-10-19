import Darwin
import Foundation

enum CaseCLIInstallerError: Error, Equatable {
    case unknownFlavor
    /// Something that is not a symlink already uses the name; it is left alone.
    case occupied(String)
    case failed(String)

    var userMessage: String {
        switch self {
        case .unknownFlavor: return "неизвестный вариант сборки"
        case .occupied(let path): return "\(path) уже занят другим файлом"
        case .failed(let path): return "не удалось создать ссылку \(path)"
        }
    }
}

/// Puts `whytap` (prod), `whytap-beta` or `whytap-dev` on PATH as a symlink to
/// the helper inside the running app. Each flavor owns only its own name, so
/// beta and dev never take over `whytap`. A regular file or folder with that
/// name belongs to the user and is never replaced.
enum CaseCLIInstaller {
    static var defaultBinDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    }

    /// Source dev bundles (9999 / -dev) are `dev` whatever their compile flavor.
    static var currentFlavorName: String {
        flavorName(flavor: BuildConfig.flavor, allowsPackagedUpdates: BuildConfig.allowsPackagedUpdates)
    }

    static func flavorName(flavor: BuildFlavor, allowsPackagedUpdates: Bool) -> String {
        allowsPackagedUpdates ? flavor.rawValue : BuildFlavor.dev.rawValue
    }

    static func commandName(flavorName: String) throws -> String {
        switch flavorName {
        case BuildFlavor.prod.rawValue: return "whytap"
        case BuildFlavor.beta.rawValue: return "whytap-beta"
        case BuildFlavor.dev.rawValue: return "whytap-dev"
        default: throw CaseCLIInstallerError.unknownFlavor
        }
    }

    @discardableResult
    static func install(flavorName: String, helperURL: URL, binDir: URL) throws -> URL {
        let link = binDir.appendingPathComponent(try commandName(flavorName: flavorName))
        let fm = FileManager.default

        var info = stat()
        if lstat(link.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFLNK else { throw CaseCLIInstallerError.occupied(link.path) }
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == helperURL.path { return link }
        }

        do {
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            // Build next to it and rename over: the name never points nowhere.
            let temporary = binDir.appendingPathComponent(".\(link.lastPathComponent).\(UUID().uuidString)")
            try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: helperURL.path)
            guard rename(temporary.path, link.path) == 0 else {
                try? fm.removeItem(at: temporary)
                throw CaseCLIInstallerError.failed(link.path)
            }
        } catch let error as CaseCLIInstallerError {
            throw error
        } catch {
            throw CaseCLIInstallerError.failed(link.path)
        }
        return link
    }
}
