import Foundation

/// Presentation fallback for completed answers, never a tool or an authorization.
/// Keeps the existing actions renderer and keyboard controls independent of
/// whether the model remembered to call show_actions. No network or file I/O.
enum NativeAgentAnswerArtifacts {
    static func merging(_ existing: UsefulActionsBlock?, _ incoming: UsefulActionsBlock) -> UsefulActionsBlock {
        var seen = Set<String>()
        let items = ((existing?.items ?? []) + incoming.items).filter { seen.insert($0.insertText).inserted }
        return UsefulActionsBlock(items: items)
    }

    static func collect(from answer: String, existing: UsefulActionsBlock? = nil,
                        homeDirectory: String = NSHomeDirectory()) -> UsefulActionsBlock? {
        let text = String(answer.prefix(32_000))
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var candidates: [(NSRange, ActionItem)] = []
        var excluded: [NSRange] = []
        var occupied: [NSRange] = []
        func overlaps(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
            ranges.contains { NSIntersectionRange(range, $0).length > 0 }
        }
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            Array(((try? NSRegularExpression(pattern: pattern).matches(in: text, range: full)) ?? []).prefix(100))
        }
        func path(_ raw: String, decodePercent: Bool = false) -> ActionItem? {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
            if decodePercent { value = value.removingPercentEncoding ?? value }
            if value.hasPrefix("file://"), let url = URL(string: value),
               url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" { value = url.path }
            if value.hasPrefix("~/") { value = homeDirectory + String(value.dropFirst()) }
            guard value.hasPrefix("/"), !value.hasPrefix("//"),
                  !value.contains("://"), !value.contains(where: { $0.isNewline }),
                  !value.contains(" && "), !value.contains(" | "), !value.contains("; ") else { return nil }
            let name = (value as NSString).lastPathComponent
            return .path(path: value, description: name.isEmpty ? value : name)
        }
        // Code/config examples aren't source links. A fence containing only a
        // path/URL remains a copyable value and can also get its usual card.
        for fence in matches(#"(?s)```([^\n`]*)\n(.*?)```"#) {
            excluded.append(fence.range)
            let language = ns.substring(with: fence.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
            guard ["", "text", "plaintext", "path"].contains(language) else { continue }
            let body = ns.substring(with: fence.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let item = path(body) { candidates.append((fence.range, item)) }
            else if let url = webURL(body) { candidates.append((fence.range, link(url))) }
        }
        let markdown = matches(#"\[([^\]\r\n]{1,120})\]\(([^)\r\n]+)\)"#)
            .filter { !overlaps($0.range, excluded) }
        for match in markdown {
            var target = ns.substring(with: match.range(at: 2))
            if let title = target.range(of: #"\s+["'][^"']*["']$"#, options: .regularExpression) {
                target.removeSubrange(title)
            }
            if let item = path(target, decodePercent: true) {
                candidates.append((match.range, item)); occupied.append(match.range)
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: text, range: full) { match, _, stop in
                guard let match else { return }
                if candidates.count >= 100 { stop.pointee = true; return }
                occupied.append(match.range)
                guard !overlaps(match.range, excluded), let detected = match.url,
                      let url = webURL(detected.absoluteString) else { return }
                let label = markdown.first { NSIntersectionRange($0.range, match.range) == match.range }
                    .map { ns.substring(with: $0.range(at: 1)) }
                candidates.append((match.range, link(url, label: label)))
            }
        }
        for match in matches(#"`([^`\r\n]+)`|["“«]((?:/|~/)[^"”»\r\n]+)["”»]"#) {
            guard !overlaps(match.range, excluded + occupied) else { continue }
            let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            if let item = path(ns.substring(with: range)) {
                candidates.append((match.range, item)); occupied.append(match.range)
            }
        }
        // Unquoted paths are conservative. Space-containing paths are supported
        // in code spans, quotes and Markdown destinations without guessing where
        // the surrounding sentence ends.
        for match in matches(#"(?<![\p{L}\p{N}_:/])(?:~/|/(?:Users|Volumes|Applications|Library|System|private|tmp|var|opt|usr|etc|home)/)[^\s`<>"'\[\]{}]+"#) {
            guard !overlaps(match.range, excluded + occupied) else { continue }
            let value = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}»”"))
            if let item = path(value) { candidates.append((match.range, item)) }
        }
        var seen = Set<String>()
        let inferred = candidates.sorted { $0.0.location < $1.0.location }.map(\.1)
            .filter { seen.insert($0.insertText).inserted }
        let block = merging(existing, UsefulActionsBlock(items: inferred))
        return block.items.isEmpty ? nil : block
    }

    private static func webURL(_ text: String) -> URL? {
        guard !text.contains(where: { $0.isWhitespace }),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func link(_ url: URL, label: String? = nil) -> ActionItem {
        let label = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = label.isEmpty ? (url.host ?? url.absoluteString) : label
        return .link(url: url, description: String(description.prefix(UsefulLink.maxDescriptionLength)), provider: nil)
    }
}
