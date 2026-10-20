import XCTest

/// Case code handles key values, commands and prompts, so it must not log at
/// all. The one allowed call is the Keychain migration status code in
/// `CaseVaultKeyStore` (a number, never key material).
final class CaseLoggingGuardTests: XCTestCase {
    static let guardedDirectories = ["Sources/Sidekey/Case", "Sources/WhytapCaseKit", "Sources/WhytapCLI"]
    static let allowed: [(file: String, marker: String)] = [
        ("Sources/Sidekey/Case/CaseVaultKeyStore.swift", "case_vault_key_accessibility_migration_failed"),
    ]

    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(os_log|NSLog|print|debugPrint|dump|os_signpost)\s*\(|\bLogger\b"#)

    /// Logging calls in `source`, by line number (line comments ignored).
    static func loggingLines(in source: String) -> [(line: Int, text: String)] {
        var hits: [(Int, String)] = []
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            var code = raw
            if let comment = code.range(of: "//") { code = String(code[..<comment.lowerBound]) }
            let range = NSRange(code.startIndex..., in: code)
            if pattern.firstMatch(in: code, range: range) != nil { hits.append((index + 1, raw)) }
        }
        return hits
    }

    func test_scanner_finds_logging_calls() {
        let sample = """
        let a = 1 // print("not code")
        os_log("x", log: log)
        private static let log = Logger(subsystem: "s", category: "c")
        print("value")
        Swift.print ("value")
        let printer = 2
        """
        XCTAssertEqual(Self.loggingLines(in: sample).map(\.line), [2, 3, 4, 5])
    }

    func test_case_sources_do_not_log() throws {
        let root = try projectRoot()
        var unexpected: [String] = []
        var allowedSeen = 0
        for directory in Self.guardedDirectories {
            let base = root.appendingPathComponent(directory)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            XCTAssertFalse(files.isEmpty, "\(directory) has no sources: the guard would pass vacuously")
            for file in files {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                let source = try String(contentsOf: file, encoding: .utf8)
                for hit in Self.loggingLines(in: source) {
                    let lines = source.components(separatedBy: "\n")
                    let window = lines[(hit.line - 1)..<min(lines.count, hit.line + 3)].joined(separator: " ")
                    if let rule = Self.allowed.first(where: { $0.file == relative }), window.contains(rule.marker) {
                        allowedSeen += 1
                        continue
                    }
                    unexpected.append("\(relative):\(hit.line): \(hit.text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(unexpected, [], "Case code must not log")
        XCTAssertEqual(allowedSeen, Self.allowed.count, "the allowed status-code log moved; update the guard")
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "CaseLoggingGuardTests", code: 1)
    }
}
