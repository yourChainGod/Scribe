//
//  TextFormatTests.swift
//  Sanity tests for the encoding + line-ending detector. Locks the heuristic
//  behaviour described in the comments of TextFormat.swift.
//

import XCTest
@testable import Scribe

final class TextFormatTests: XCTestCase {

    // MARK: - BOM detection

    func testUTF8BOMStripsAndDecodes() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let bytes = bom + Array("hello 你好".utf8)
        let result = TextFormatDetector.decode(data: Data(bytes))
        XCTAssertEqual(result.encoding, .utf8WithBOM)
        XCTAssertEqual(result.text, "hello 你好")
    }

    func testUTF16LEBOM() {
        var data = Data([0xFF, 0xFE])
        data.append("hi".data(using: .utf16LittleEndian)!)
        let result = TextFormatDetector.decode(data: data)
        XCTAssertEqual(result.encoding, .utf16LE)
        XCTAssertEqual(result.text, "hi")
    }

    func testUTF16BEBOM() {
        var data = Data([0xFE, 0xFF])
        data.append("hi".data(using: .utf16BigEndian)!)
        let result = TextFormatDetector.decode(data: data)
        XCTAssertEqual(result.encoding, .utf16BE)
        XCTAssertEqual(result.text, "hi")
    }

    // MARK: - No BOM heuristics

    func testPlainAsciiBecomesUTF8() {
        let result = TextFormatDetector.decode(data: Data("plain ascii".utf8))
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertEqual(result.text, "plain ascii")
    }

    func testValidUTF8WithChinese() {
        let result = TextFormatDetector.decode(data: Data("中文测试".utf8))
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertEqual(result.text, "中文测试")
    }

    func testGBKChineseFallback() {
        let original = "中文测试"
        let gbk = TextEncoding.gb18030.stringEncoding
        guard let bytes = original.data(using: gbk) else {
            XCTFail("Cannot encode test fixture as GBK")
            return
        }
        // Sanity: GBK bytes must not be valid UTF-8.
        XCTAssertNil(String(data: bytes, encoding: .utf8))

        let result = TextFormatDetector.decode(data: bytes)
        XCTAssertEqual(result.encoding, .gb18030)
        XCTAssertEqual(result.text, original)
    }

    // MARK: - Line endings

    func testDetectLF() {
        XCTAssertEqual(TextFormatDetector.detectLineEnding(in: "a\nb\nc"), .lf)
    }

    func testDetectCRLF() {
        XCTAssertEqual(TextFormatDetector.detectLineEnding(in: "a\r\nb\r\nc"), .crlf)
    }

    func testDetectCR() {
        XCTAssertEqual(TextFormatDetector.detectLineEnding(in: "a\rb\rc"), .cr)
    }

    func testMixedFavoursMajority() {
        // Two CRLF vs one bare LF — CRLF should win.
        XCTAssertEqual(TextFormatDetector.detectLineEnding(in: "a\r\nb\r\nc\nd"),
                       .crlf)
    }

    func testNormaliseStripsCRs() {
        XCTAssertEqual(TextFormatDetector.normalize("a\r\nb\rc\nd"), "a\nb\nc\nd")
    }

    // MARK: - Round-trip

    func testRoundTripCRLFGBK() {
        let original = "第一行\n第二行\n第三行"
        guard let payload = TextFormatDetector.encode(
                original,
                encoding: .gb18030,
                lineEnding: .crlf) else {
            XCTFail("encode returned nil")
            return
        }
        // Bytes on disk must use CRLF
        XCTAssertTrue(payload.contains(0x0D))
        let decoded = TextFormatDetector.decode(data: payload)
        XCTAssertEqual(decoded.encoding, .gb18030)
        XCTAssertEqual(decoded.lineEnding, .crlf)
        XCTAssertEqual(decoded.text, original)
    }

    func testRoundTripUTF8BOMLF() {
        let original = "Hello 🚀\nLine 2"
        guard let payload = TextFormatDetector.encode(
                original,
                encoding: .utf8WithBOM,
                lineEnding: .lf) else {
            XCTFail("encode returned nil")
            return
        }
        // Must start with EF BB BF
        XCTAssertEqual([UInt8](payload.prefix(3)), [0xEF, 0xBB, 0xBF])
        let decoded = TextFormatDetector.decode(data: payload)
        XCTAssertEqual(decoded.encoding, .utf8WithBOM)
        XCTAssertEqual(decoded.text, original)
    }

    // MARK: - BOM strip

    func testStripBOMRemovesMatchingPrefix() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let raw = Data(bom + Array("abc".utf8))
        let stripped = TextFormatDetector.stripBOM(raw, for: .utf8WithBOM)
        XCTAssertEqual(stripped, Data("abc".utf8))
    }

    func testStripBOMNoOpForPlainEncoding() {
        let raw = Data("abc".utf8)
        let stripped = TextFormatDetector.stripBOM(raw, for: .utf8)
        XCTAssertEqual(stripped, raw)
    }

    // MARK: - Phase 76 — encode failure path (guards ⌘S vs silent data loss)

    /// Emoji and CJK have no ASCII representation, so `data(using:.ascii)`
    /// returns nil and `encode` must propagate it — Workspace turns that
    /// into a save-failure toast rather than silently writing garbage.
    /// Without this guard a regression to lossy conversion would drop the
    /// characters unnoticed.
    func test_encode_nilForCharactersIncompatibleWithEncoding() {
        XCTAssertNil(TextFormatDetector.encode("🚀 rocket", encoding: .ascii,
                                               lineEnding: .lf))
        XCTAssertNil(TextFormatDetector.encode("中文", encoding: .ascii,
                                               lineEnding: .lf))
    }

    func test_encode_succeedsWhenEncodingCoversContent() {
        // The same content encodes fine in Unicode-complete encodings.
        XCTAssertNotNil(TextFormatDetector.encode("🚀", encoding: .utf8,
                                                  lineEnding: .lf))
        XCTAssertNotNil(TextFormatDetector.encode("🚀", encoding: .gb18030,
                                                  lineEnding: .lf))
        XCTAssertNotNil(TextFormatDetector.encode("中文", encoding: .gb18030,
                                                  lineEnding: .lf))
    }

    func test_encode_asciiContentRoundTripsThroughAsciiEncoding() {
        // ASCII bytes are a subset of UTF-8 bytes.
        let data = TextFormatDetector.encode("hello world", encoding: .ascii,
                                             lineEnding: .lf)
        XCTAssertEqual(data, Data("hello world".utf8))
    }

    func test_encode_emptyStringYieldsEmptyData() {
        // An empty buffer is a valid save (new empty file), not a failure.
        XCTAssertEqual(TextFormatDetector.encode("", encoding: .utf8,
                                                 lineEnding: .lf), Data())
    }

    // MARK: - Phase 76 — decode robustness on malformed / boundary input

    func test_decode_emptyDataYieldsEmptyText() {
        // Empty data hits the all-ASCII fast path (vacuously true).
        let result = TextFormatDetector.decode(data: Data())
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertEqual(result.lineEnding, .lf)
    }

    func test_decode_fourByteUTF8EmojiIsStrictUTF8() {
        // 🚀 = F0 9F 9A 80 — exercises isValidUTF8's need=3 (4-byte) arm
        // at an exact boundary (final continuation byte is the last byte).
        let result = TextFormatDetector.decode(data: Data("🚀".utf8))
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertEqual(result.text, "🚀")
    }

    func test_decode_truncatedMultibyteUTF8DoesNotCrash() {
        // "中" = E4 B8 AD; drop the final byte. The strict-UTF8 check must
        // reject it via the `i + need < count` truncation guard, so it is
        // never surfaced as the intact "中". Mainly: must not trap.
        let result = TextFormatDetector.decode(data: Data([0xE4, 0xB8]))
        XCTAssertNotEqual(result.text, "中",
                          "a torn UTF-8 tail must not surface as the whole char")
    }

    func test_decode_illegalUTF8LeadingByteDoesNotCrash() {
        // 0xFF can never lead a UTF-8 sequence (the `else { return false }`
        // arm of isValidUTF8). 0x41 keeps it clear of the UTF-16LE BOM
        // path. Must fall through to the lossy last resort without trapping.
        let result = TextFormatDetector.decode(data: Data([0xFF, 0x41]))
        XCTAssertNotEqual(result.encoding, .utf16LE,
                          "FF 41 is not a UTF-16LE BOM")
    }

    // MARK: - Phase 76 — line-ending boundaries

    func test_detectLineEnding_emptyStringIsLF() {
        XCTAssertEqual(TextFormatDetector.detectLineEnding(in: ""), .lf)
    }

    func test_detectLineEnding_noNewlineIsLF() {
        XCTAssertEqual(TextFormatDetector.detectLineEnding(in: "one line, no break"),
                       .lf)
    }

    func test_roundTrip_classicMacCR() {
        let original = "line1\nline2\nline3"
        guard let payload = TextFormatDetector.encode(original, encoding: .utf8,
                                                      lineEnding: .cr) else {
            XCTFail("encode returned nil"); return
        }
        // On disk: CR separators only, no LF.
        XCTAssertTrue(payload.contains(0x0D))
        XCTAssertFalse(payload.contains(0x0A))
        let decoded = TextFormatDetector.decode(data: payload)
        XCTAssertEqual(decoded.lineEnding, .cr)
        XCTAssertEqual(decoded.text, original) // normalised back to LF in memory
    }
}
