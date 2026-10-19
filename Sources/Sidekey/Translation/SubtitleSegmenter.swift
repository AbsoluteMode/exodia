import Foundation

/// Commits provider finals only. Partials are shown separately and never billed.
/// A short silence, a sentence end or a two-second phrase budget releases a line.
struct SubtitleSegmenter {
    private(set) var pending = ""
    private var firstAt: TimeInterval?
    private var lastAt: TimeInterval = 0

    mutating func append(_ text: String, join: BYOKTranscriptJoin, now: TimeInterval) {
        guard !text.isEmpty else { return }
        if pending.isEmpty { firstAt = now }
        if join == .wordBoundary, !pending.isEmpty,
           pending.last?.isWhitespace == false, text.first?.isWhitespace == false {
            pending += " "
        }
        pending += text
        lastAt = now
    }

    mutating func take(now: TimeInterval, force: Bool = false) -> String? {
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sentenceEnd = trimmed.last.map { ".!?。！？".contains($0) } ?? false
        guard force || trimmed.count >= 300 || now - lastAt >= 0.8
                || (sentenceEnd && now - lastAt >= 0.2)
                || (trimmed.count >= 40 && now - (firstAt ?? now) >= 2) else { return nil }
        // One bad/very large provider event cannot create an unbounded LLM request.
        let end = trimmed.index(trimmed.startIndex, offsetBy: min(600, trimmed.count))
        let split = end == trimmed.endIndex ? end
            : (trimmed[..<end].lastIndex(where: \.isWhitespace) ?? end)
        let result = String(trimmed[..<split])
        pending = String(trimmed[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        firstAt = pending.isEmpty ? nil : now
        return result
    }

    static func pcm16(_ samples: [Float]) -> Data {
        var values = samples.map { sample -> Int16 in
            guard sample.isFinite else { return 0 }
            return Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
        }
        return values.withUnsafeMutableBytes { Data($0) }
    }
}
