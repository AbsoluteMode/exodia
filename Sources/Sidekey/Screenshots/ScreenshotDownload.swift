import AppKit

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
        for index in 1...10_000 {
            try Task.checkCancellation()
            let suffix = index == 1 ? "" : " (\(index))"
            let url = directory.appendingPathComponent("\(name)\(suffix).png")
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
