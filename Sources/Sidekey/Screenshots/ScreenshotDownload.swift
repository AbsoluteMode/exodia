import AppKit
import Darwin

enum ScreenshotDownload {
    static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ScreenshotImageError.rendering
        }
        return data
    }

    /// Explicit downloads only. Exclusive writes never replace an existing user's file.
    static func write(_ data: Data, directory: URL, date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screenshot \(formatter.string(from: date))"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".Screenshot-\(UUID().uuidString).tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("image.png")
        try data.write(to: temporary, options: .atomic)
        for index in 1...10_000 {
            try Task.checkCancellation()
            let suffix = index == 1 ? "" : " (\(index))"
            let url = directory.appendingPathComponent("\(name)\(suffix).png")
            var failure: Int32 = 0
            let published = temporary.withUnsafeFileSystemRepresentation { source in
                url.withUnsafeFileSystemRepresentation { destination in
                    guard let source, let destination else { failure = EINVAL; return false }
                    if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 { return true }
                    failure = errno; return false
                }
            }
            if published { return url }
            if failure == EEXIST { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
