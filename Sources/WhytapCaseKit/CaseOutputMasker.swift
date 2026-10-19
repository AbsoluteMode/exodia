import Foundation

/// Streaming redactor for child-process output. Replaces every occurrence of
/// a secret, or of a common encoding of it, with `placeholder`. A value that
/// straddles two `feed` calls is still caught: the last `longest variant - 1`
/// bytes are held back until more data (or `finish`) arrives.
///
/// Not thread safe; use one instance per output stream.
public final class CaseOutputMasker {
    public static let minimumMaskedLength = 4
    public static let placeholder = "[case:hidden]"

    private let placeholderBytes = Array(CaseOutputMasker.placeholder.utf8)
    /// Variants indexed by first byte, longest first.
    private var byFirstByte: [[[UInt8]]] = Array(repeating: [], count: 256)
    private let maxLength: Int
    private var buffer: [UInt8] = []

    public init(secrets: [String]) {
        var set = Set<[UInt8]>()
        for secret in secrets {
            Self.collectVariants(of: secret, into: &set)
        }
        var longest = 0
        for variant in set where variant.count >= Self.minimumMaskedLength {
            byFirstByte[Int(variant[0])].append(variant)
            longest = max(longest, variant.count)
        }
        for i in 0..<256 {
            byFirstByte[i].sort { $0.count > $1.count }
        }
        maxLength = longest
    }

    /// Returns the bytes that are safe to emit now; keeps the tail.
    public func feed(_ chunk: Data) -> Data {
        guard maxLength > 0 else { return chunk }
        buffer.append(contentsOf: chunk)
        return Data(process(final: false))
    }

    /// Flushes everything still held back.
    public func finish() -> Data {
        guard maxLength > 0 else { return Data() }
        return Data(process(final: true))
    }

    // MARK: Scanning

    private func process(final: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(buffer.count)
        let n = buffer.count
        var i = 0
        scan: while i < n {
            // A variant starting here is only decidable with maxLength bytes in view.
            if !final && n - i < maxLength { break }
            guard let first = longestMatch(at: i) else {
                out.append(buffer[i])
                i += 1
                continue
            }
            var end = i + first
            // Merge variants that start inside the match and run past it,
            // so overlapping secrets leave no fragment behind.
            var j = i + 1
            while j < end {
                if !final && n - j < maxLength { break scan }
                if let m = longestMatch(at: j), j + m > end { end = j + m }
                j += 1
            }
            out.append(contentsOf: placeholderBytes)
            i = end
        }
        buffer = i < n ? Array(buffer[i...]) : []
        return out
    }

    private func longestMatch(at i: Int) -> Int? {
        let remaining = buffer.count - i
        for variant in byFirstByte[Int(buffer[i])] where variant.count <= remaining {
            var k = 1
            while k < variant.count && buffer[i + k] == variant[k] { k += 1 }
            if k == variant.count { return variant.count }
        }
        return nil
    }

    // MARK: Variants

    private static func collectVariants(of secret: String, into set: inout Set<[UInt8]>) {
        let whole = Array(secret.utf8)
        guard whole.count >= minimumMaskedLength else { return }

        var texts: [String] = [secret]
        if secret.contains("\n") || secret.contains("\r") {
            for line in secret.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
                let s = String(line)
                if s.utf8.count >= minimumMaskedLength { texts.append(s) }
            }
        }
        for text in texts {
            let bytes = Array(text.utf8)
            set.insert(bytes)
            for v in base64Variants(bytes) { set.insert(v) }
            set.insert(Array(hex(bytes, upper: false).utf8))
            set.insert(Array(hex(bytes, upper: true).utf8))
            if let p = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { set.insert(Array(p.utf8)) }
            if let p = text.addingPercentEncoding(withAllowedCharacters: unreserved) { set.insert(Array(p.utf8)) }
            for j in jsonEscapes(text) { set.insert(Array(j.utf8)) }
        }
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func hex(_ bytes: [UInt8], upper: Bool) -> String {
        let digits = Array((upper ? "0123456789ABCDEF" : "0123456789abcdef").utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }

    private static func jsonEscapes(_ text: String) -> [String] {
        var result: [String] = []
        for options: JSONEncoder.OutputFormatting in [[], [.withoutEscapingSlashes]] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = options
            if let data = try? encoder.encode(text), data.count >= 2 {
                result.append(String(decoding: data.dropFirst().dropLast(), as: UTF8.self))
            }
        }
        return result
    }

    /// Base64 as it can appear inside a larger encoded blob. The value may
    /// begin at byte offset 0, 1 or 2 of a 3-byte group, which changes the
    /// characters around it. For each offset only the characters that depend
    /// on value bytes alone are kept (like GitHub's Base64StringEscapeShift).
    /// Offset 0 additionally keeps the full padded and unpadded encodings so
    /// a standalone encoded value leaves no trailing fragment.
    private static func base64Variants(_ bytes: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for shift in 0..<3 {
            let encoded = Data(repeating: 0, count: shift) + Data(bytes)
            let std = Array(encoded.base64EncodedString().utf8).filter { $0 != UInt8(ascii: "=") }
            let url = std.map { c -> UInt8 in
                c == UInt8(ascii: "+") ? UInt8(ascii: "-") : (c == UInt8(ascii: "/") ? UInt8(ascii: "_") : c)
            }
            let startBit = 8 * shift
            let endBit = 8 * (shift + bytes.count)
            let lo = (startBit + 5) / 6
            let hi = endBit / 6
            guard hi - lo >= minimumMaskedLength else { continue }
            out.append(Array(std[lo..<hi]))
            out.append(Array(url[lo..<hi]))
            if shift == 0 {
                let padded = Array(Data(bytes).base64EncodedString().utf8)
                out.append(padded)
                out.append(padded.map { c -> UInt8 in
                    c == UInt8(ascii: "+") ? UInt8(ascii: "-") : (c == UInt8(ascii: "/") ? UInt8(ascii: "_") : c)
                })
                out.append(std)
                out.append(url)
            }
        }
        return out
    }
}
