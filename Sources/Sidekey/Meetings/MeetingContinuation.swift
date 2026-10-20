import Foundation

/// A fresh recording contributes to an existing note only after Reconnect.
/// Audio and provider checkpoints remain isolated per recording directory.
struct MeetingContinuation: Codable, Equatable, Sendable {
    let meetingId: UUID
    let precedingRecordingId: UUID
    let startedAt: Date
    let audioOffsetSeconds: TimeInterval
    let gapSeconds: TimeInterval
    var partNumber: Int = 2

    static func gapLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }
}

enum MeetingContinuationError: Error, CustomStringConvertible {
    case previousPartNotReady
    case missingMeeting

    var description: String {
        switch self {
        case .previousPartNotReady:
            return "The previous part is not ready yet. This recording is saved and will be retried."
        case .missingMeeting:
            return "The original meeting is unavailable. This recording is saved on this Mac."
        }
    }
}

/// Append each part's findings to the existing protocol without re-sending old
/// audio or replacing manual edits. Header positions follow protocol:v1.
enum MeetingContinuationMarkdown {
    static func appending(_ addition: String, to existing: String) -> String {
        let original = existing.components(separatedBy: .newlines)
        let fresh = addition.components(separatedBy: .newlines)
        let oldHeaders = original.indices.filter { original[$0].hasPrefix("## ") }
        let newHeaders = fresh.indices.filter { fresh[$0].hasPrefix("## ") }
        guard oldHeaders.count == 3, newHeaders.count == 3 else {
            let body = fresh.filter { $0 != MeetingProtocolParser.marker }
                .map { $0.hasPrefix("# ") ? "##" + $0 : $0 }.joined(separator: "\n")
            let generic = existing.replacingOccurrences(of: MeetingProtocolParser.marker, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return generic + "\n\n---\n\n" + body
        }
        let summary = fresh[..<newHeaders[0]].filter {
            !$0.hasPrefix("# ") && $0 != MeetingProtocolParser.marker
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var result = Array(original[..<oldHeaders[0]])
        if !summary.isEmpty { result += [summary, ""] }
        for index in 0..<3 {
            let oldEnd = index < 2 ? oldHeaders[index + 1] : original.endIndex
            let newEnd = index < 2 ? newHeaders[index + 1] : fresh.endIndex
            var oldBody = Array(original[(oldHeaders[index] + 1)..<oldEnd])
            let newBody = Array(fresh[(newHeaders[index] + 1)..<newEnd]).filter {
                $0.trimmingCharacters(in: .whitespaces) != "- None"
            }
            if newBody.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                oldBody.removeAll { $0.trimmingCharacters(in: .whitespaces) == "- None" }
            }
            result += [original[oldHeaders[index]]] + oldBody + newBody + [""]
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
