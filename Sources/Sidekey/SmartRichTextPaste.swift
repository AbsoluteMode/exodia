import AppKit
import Foundation

/// Local conversion for rich-text composers. The model produces a small
/// Markdown subset; no HTML from the model is executed or loaded.
// WHY: .project-docs/decisions/2026-10-21-smart-destination-formatting.md
struct SmartRichTextPaste {
    let plainText: String
    let rtf: Data
    let html: Data?

    @MainActor
    static func make(_ markdown: String) -> Self? {
        guard !markdown.isEmpty, markdown.count <= 32_000 else { return nil }
        let result = NSMutableAttributedString(string: "")
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let codeFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        var fallback = ""
        var html = ""
        func escapeHTML(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }

        func appendInline(_ text: String) throws {
            // Unsupported raw HTML/images stay literal. Do not drop their
            // visible text or turn a dictated URL into an embedded resource.
            let inlineCode = text.hasPrefix("`") && text.hasSuffix("`")
            let unsupportedMarkup = text.range(of: "<[A-Za-z!/][^>]*>", options: .regularExpression) != nil || text.contains("![")
            if !inlineCode && unsupportedMarkup {
                result.append(NSAttributedString(string: text, attributes: [.font: font]))
                fallback += text
                html += escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>")
                return
            }
            let parsed = try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            var pendingLink: URL?
            var pendingLabel = ""
            func finishLink() {
                if let pendingLink, pendingLabel != pendingLink.absoluteString { fallback += " (\(pendingLink.absoluteString))" }
            }
            for run in parsed.runs {
                if run.link != pendingLink { finishLink(); pendingLink = run.link; pendingLabel = "" }
                let value = String(parsed[run.range].characters)
                let intent = run.inlinePresentationIntent ?? []
                var attributes: [NSAttributedString.Key: Any] = [.font: intent.contains(.code) ? codeFont : font]
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty { attributes[.font] = NSFontManager.shared.convert(attributes[.font] as! NSFont, toHaveTrait: traits) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = link }
                result.append(NSAttributedString(string: value, attributes: attributes))
                var markup = escapeHTML(value).replacingOccurrences(of: "\n", with: "<br>")
                if intent.contains(.code) { markup = "<code>\(markup)</code>" }
                if intent.contains(.stronglyEmphasized) { markup = "<strong>\(markup)</strong>" }
                if intent.contains(.emphasized) { markup = "<em>\(markup)</em>" }
                if intent.contains(.strikethrough) { markup = "<s>\(markup)</s>" }
                if let link = run.link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                    markup = "<a href=\"\(escapeHTML(link.absoluteString))\">\(markup)</a>"
                }
                html += markup
                fallback += value
                if pendingLink != nil { pendingLabel += value }
            }
            finishLink()
        }

        // Fences are handled separately so indentation, literal Markdown and
        // filler words inside code survive Foundation's inline parser exactly.
        let ranges = SmartMarkdownProtection.literalRanges(in: markdown)
        let ns = markdown as NSString
        var offset = 0
        do {
            for range in ranges {
                if range.location > offset { try appendInline(ns.substring(with: NSRange(location: offset, length: range.location - offset))) }
                let source = ns.substring(with: range)
                if source.hasPrefix("https://") || source.hasPrefix("http://") {
                    result.append(NSAttributedString(string: source, attributes: [.font: font]))
                    fallback += source
                    html += escapeHTML(source)
                } else if let code = SmartMarkdownProtection.fencedBody(source) {
                    result.append(NSAttributedString(string: code, attributes: [.font: codeFont]))
                    fallback += code
                    html += "<pre><code>\(escapeHTML(code))</code></pre>"
                } else if source.contains("\n") && (source.trimmingCharacters(in: .whitespaces).hasPrefix("```") || source.trimmingCharacters(in: .whitespaces).hasPrefix("~~~")) {
                    result.append(NSAttributedString(string: source, attributes: [.font: font]))
                    fallback += source
                    html += escapeHTML(source).replacingOccurrences(of: "\n", with: "<br>")
                } else {
                    try appendInline(source)
                }
                offset = NSMaxRange(range)
            }
            if offset < ns.length { try appendInline(ns.substring(from: offset)) }
        } catch { return nil }
        guard !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let range = NSRange(location: 0, length: result.length)
        guard let rtf = try? result.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return nil }
        return Self(plainText: fallback, rtf: rtf, html: Data("<html><body>\(html)</body></html>".utf8))
    }
}

enum SmartMarkdownProtection {
    static func literalRanges(in text: String) -> [NSRange] {
        let code = codeRanges(in: text)
        let ns = text as NSString
        let urls = (try? NSRegularExpression(pattern: "https?://[^\\s<>()]+"))?
            .matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range) ?? []
        let bareURLs = urls.filter { range in
            // An explicit Markdown link has its own parser, which treats its
            // destination literally; splitting it would damage its syntax.
            if range.location >= 2, ns.substring(with: NSRange(location: range.location - 2, length: 2)) == "](" { return false }
            return !code.contains { NSIntersectionRange($0, range).length > 0 }
        }
        return (code + bareURLs).sorted { $0.location < $1.location }
    }

    /// Disjoint ranges, ordered by source offset. Unclosed fences are literal
    /// protected text rather than an excuse to discard the rest of the message.
    static func codeRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var fenced: [NSRange] = []
        var opening: (start: Int, character: Character, count: Int)?
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let character = trimmed.first, character == "`" || character == "~" {
                let count = trimmed.prefix(while: { $0 == character }).count
                if count >= 3 {
                    if let start = opening {
                        let suffix = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
                        if character == start.character, count >= start.count, suffix.isEmpty {
                            fenced.append(NSRange(location: start.start, length: offset + (line as NSString).length - start.start))
                            opening = nil
                        }
                    } else { opening = (offset, character, count) }
                }
            }
            offset += (line as NSString).length + 1
        }
        if let opening { fenced.append(NSRange(location: opening.start, length: ns.length - opening.start)) }
        let inline = (try? NSRegularExpression(pattern: "(`+)([\\s\\S]*?)\\1"))?
            .matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range) ?? []
        return (fenced + inline.filter { range in !fenced.contains { NSIntersectionRange($0, range).length > 0 } })
            .sorted { $0.location < $1.location }
    }

    static func fencedBody(_ text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2, let first = lines.first?.trimmingCharacters(in: .whitespaces),
              let char = first.first, char == "`" || char == "~" else { return nil }
        let count = first.prefix(while: { $0 == char }).count
        let last = lines.last!.trimmingCharacters(in: .whitespaces)
        guard count >= 3, last.count >= count, last.allSatisfy({ $0 == char }) else { return nil }
        lines.removeFirst(); lines.removeLast()
        return lines.joined(separator: "\n")
    }

    static func filtering(_ text: String, apply: (String) -> String) -> String {
        let ranges = literalRanges(in: text)
        guard !ranges.isEmpty else { return apply(text) }
        let ns = text as NSString
        var masked = text
        var replacements: [(String, String)] = []
        for (index, range) in ranges.enumerated().reversed() {
            let digits = String(index, radix: 2).map { $0 == "0" ? "\u{E001}" : "\u{E002}" }.joined()
            let token = "\u{E000}\(digits)\u{E003}"
            guard !text.contains(token) else { return text }
            replacements.append((token, ns.substring(with: range)))
            masked = (masked as NSString).replacingCharacters(in: range, with: token)
        }
        var output = apply(masked)
        for (token, value) in replacements { output = output.replacingOccurrences(of: token, with: value) }
        return output
    }
}
