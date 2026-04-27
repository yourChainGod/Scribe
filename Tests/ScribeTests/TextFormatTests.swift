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
}
