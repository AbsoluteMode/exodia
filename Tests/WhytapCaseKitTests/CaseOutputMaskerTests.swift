import XCTest
@testable import WhytapCaseKit

final class CaseOutputMaskerTests: XCTestCase {
    private let secret = "sk-test-Zx9/Qw+7_notreal"
    private let hidden = CaseOutputMasker.placeholder

    private func mask(_ text: String, secrets: [String], chunk: Int? = nil) -> String {
        let m = CaseOutputMasker(secrets: secrets)
        let data = Data(text.utf8)
        var out = Data()
        if let chunk {
            var i = 0
            while i < data.count {
                out.append(m.feed(data.subdata(in: i..<min(i + chunk, data.count))))
                i += chunk
            }
        } else {
            out.append(m.feed(data))
        }
        out.append(m.finish())
        return String(decoding: out, as: UTF8.self)
    }

    func test_constants() {
        XCTAssertEqual(CaseOutputMasker.placeholder, "[case:hidden]")
        XCTAssertEqual(CaseOutputMasker.minimumMaskedLength, 4)
    }

    func test_masks_raw_value() {
        XCTAssertEqual(mask("token=\(secret)!\n", secrets: [secret]), "token=\(hidden)!\n")
        XCTAssertEqual(mask("\(secret)\(secret)", secrets: [secret]), "\(hidden)\(hidden)")
    }

    func test_masks_base64_all_offsets() {
        let v = Data(secret.utf8)
        for prefix in ["", "a", "ab", "abc", "abcd"] {
            for suffix in ["", "z", "zy"] {
                let blob = Data(prefix.utf8) + v + Data(suffix.utf8)
                for encoded in [blob.base64EncodedString(), Self.urlSafe(blob)] {
                    let out = mask("hdr \(encoded) end", secrets: [secret])
                    XCTAssertFalse(Self.leaksInner(out, of: v), "prefix=\(prefix) suffix=\(suffix) out=\(out)")
                    XCTAssertTrue(out.contains(hidden), "prefix=\(prefix) suffix=\(suffix)")
                }
            }
        }
    }

    func test_base64_of_exact_value_leaves_no_trailing_fragment() {
        let encoded = Data(secret.utf8).base64EncodedString()
        XCTAssertEqual(mask("x \(encoded) y", secrets: [secret]), "x \(hidden) y")
    }

    func test_masks_hex_and_json_and_percent() {
        let v = "pa$$ w/\"rd&=é"
        let hex = Data(v.utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(mask("a\(hex)b", secrets: [v]), "a\(hidden)b")
        XCTAssertEqual(mask("a\(hex.uppercased())b", secrets: [v]), "a\(hidden)b")

        let json = String(decoding: try! JSONEncoder().encode(v), as: UTF8.self).dropFirst().dropLast()
        XCTAssertEqual(mask("{\"k\":\"\(json)\"}", secrets: [v]), "{\"k\":\"\(hidden)\"}")

        let pct = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        XCTAssertNotEqual(pct, v)
        XCTAssertEqual(mask("?q=\(pct)&x", secrets: [v]), "?q=\(hidden)&x")
    }

    func test_value_split_across_feeds_is_masked() {
        let text = "before \(secret) after \(secret)"
        for size in [1, 2, 3, 5, 7, 11] {
            XCTAssertEqual(mask(text, secrets: [secret], chunk: size), "before \(hidden) after \(hidden)", "chunk=\(size)")
        }
        // Explicit split mid-value; nothing of the value is emitted at the boundary.
        let m = CaseOutputMasker(secrets: [secret])
        let first = m.feed(Data("a \(secret.prefix(9))".utf8))
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains(String(secret.prefix(4))))
        let second = m.feed(Data("\(secret.dropFirst(9)) z".utf8))
        let rest = m.finish()
        XCTAssertEqual(String(decoding: first + second + rest, as: UTF8.self), "a \(hidden) z")
    }

    func test_split_encoded_value_is_masked() {
        let encoded = Data(secret.utf8).base64EncodedString()
        XCTAssertEqual(mask("<\(encoded)>", secrets: [secret], chunk: 3), "<\(hidden)>")
    }

    func test_multiline_value_masked_per_line() {
        let pem = "-----BEGIN KEY-----\nAAAAbbbbCCCCdddd\nEEEEffffGGGGhhhh\n-----END KEY-----"
        let out = mask("log: EEEEffffGGGGhhhh only\nwhole:\n\(pem)\n", secrets: [pem])
        XCTAssertFalse(out.contains("EEEEffffGGGGhhhh"))
        XCTAssertFalse(out.contains("AAAAbbbbCCCCdddd"))
        XCTAssertTrue(out.hasPrefix("log: \(hidden) only"))
        // CRLF-terminated lines
        let crlf = mask("x AAAAbbbbCCCCdddd\r\n", secrets: [pem])
        XCTAssertEqual(crlf, "x \(hidden)\r\n")
    }

    func test_values_shorter_than_4_are_not_masked() {
        XCTAssertEqual(mask("abc 123 ab", secrets: ["abc", "123", "ab", ""]), "abc 123 ab")
        XCTAssertEqual(mask("abcd", secrets: ["abc", "abcd"]), hidden)
        // short lines of a multi-line value are not masked, long ones are
        XCTAssertEqual(mask("ab LONGLINE\n", secrets: ["ab\nLONGLINE"]), "ab \(hidden)\n")
    }

    func test_output_without_secrets_is_byte_identical() {
        let m = CaseOutputMasker(secrets: [secret, "another-secret-value"])
        var input = Data()
        for i in 0..<5000 { input.append(UInt8(truncatingIfNeeded: i &* 31 &+ 7)) }
        input.append(contentsOf: Array("plain text 日本語\n".utf8))
        var out = Data()
        var i = 0
        while i < input.count {
            out.append(m.feed(input.subdata(in: i..<min(i + 13, input.count))))
            i += 13
        }
        out.append(m.finish())
        XCTAssertEqual(out, input)
    }

    func test_no_secrets_passes_through_immediately() {
        let m = CaseOutputMasker(secrets: [])
        XCTAssertEqual(m.feed(Data("hello".utf8)), Data("hello".utf8))
        XCTAssertEqual(m.finish(), Data())
    }

    func test_tail_is_held_until_finish_and_flushed() {
        let m = CaseOutputMasker(secrets: [secret])
        let a = m.feed(Data("ab".utf8))
        XCTAssertEqual(a, Data())
        XCTAssertEqual(m.finish(), Data("ab".utf8))
        XCTAssertEqual(m.finish(), Data(), "second finish emits nothing")
    }

    func test_overlapping_secrets_leave_no_fragment() {
        let a = "AAAA-BBBB-CCCC"
        let b = "CCCC-DDDD-EEEE"
        let out = mask("x AAAA-BBBB-CCCC-DDDD-EEEE y", secrets: [a, b])
        XCTAssertEqual(out, "x \(hidden) y")
        XCTAssertEqual(mask("x AAAA-BBBB-CCCC-DDDD-EEEE y", secrets: [a, b], chunk: 1), "x \(hidden) y")
    }

    func test_longer_secret_wins_over_its_prefix_secret() {
        XCTAssertEqual(mask("v=abcdefgh;", secrets: ["abcd", "abcdefgh"]), "v=\(hidden);")
    }

    // MARK: helpers

    private static func urlSafe(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// True when a long stable chunk of the secret's base64 survives in `out`.
    private static func leaksInner(_ out: String, of v: Data) -> Bool {
        // Inner stable base64 of the middle of the value, any alignment, either alphabet.
        let mid = v.subdata(in: 6..<(v.count - 6))
        for k in 0..<3 {
            let enc = (Data(repeating: 0x41, count: k) + mid).base64EncodedString()
            let inner = String(enc.dropFirst(4).dropLast(4))
            let url = inner.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            if out.contains(inner) || out.contains(url) { return true }
        }
        return false
    }
}
