//
//  ColorScannerTests.swift
//  Phase 41f — color literal recognition coverage. Each form has
//  a happy-path assertion and at least one boundary / negative case.
//

import XCTest
@testable import Scribe

final class ColorScannerTests: XCTestCase {

    // MARK: - Hex

    func test_hex_short3() {
        let hits = ColorScanner.scan("#abc")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].byteRange, 0..<4)
        XCTAssertEqual(hits[0].color, .init(r: 0xAA, g: 0xBB, b: 0xCC, a: 0xFF))
    }

    func test_hex_short4_withAlpha() {
        let hits = ColorScanner.scan("#abcd")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].color, .init(r: 0xAA, g: 0xBB, b: 0xCC, a: 0xDD))
    }

    func test_hex_long6() {
        let hits = ColorScanner.scan("#1A2B3C")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].color, .init(r: 0x1A, g: 0x2B, b: 0x3C, a: 0xFF))
    }

    func test_hex_long8() {
        let hits = ColorScanner.scan("#1A2B3C7F")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].color, .init(r: 0x1A, g: 0x2B, b: 0x3C, a: 0x7F))
    }

    func test_hex_caseInsensitive() {
        let upper = ColorScanner.scan("#FFAA00")
        let lower = ColorScanner.scan("#ffaa00")
        XCTAssertEqual(upper.first?.color, lower.first?.color)
    }

    func test_hex_mid_identifier_skipped() {
        // `id="#fff"` should still match — the `"` is not an
        // identifier byte. But `my#fff` should NOT match.
        XCTAssertEqual(ColorScanner.scan("my#fff").count, 0)
        let hits = ColorScanner.scan("id=\"#fff\"")
        XCTAssertEqual(hits.count, 1)
    }

    func test_hex_runWithExtraDigit_rejected() {
        // 7 hex chars in a row is ambiguous; reject rather than guess.
        XCTAssertEqual(ColorScanner.scan("#1234567").count, 0)
    }

    func test_hex_runWithFiveDigits_rejected() {
        // 5 chars isn't any valid form.
        XCTAssertEqual(ColorScanner.scan("#12345").count, 0)
    }

    // MARK: - rgb / rgba

    func test_rgb_basic() {
        let hits = ColorScanner.scan("rgb(255, 128, 0)")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].color, .init(r: 255, g: 128, b: 0, a: 0xFF))
    }

    func test_rgb_caseInsensitive() {
        let hits = ColorScanner.scan("RGB(10, 20, 30)")
        XCTAssertEqual(hits.first?.color, .init(r: 10, g: 20, b: 30, a: 0xFF))
    }

    func test_rgb_percent() {
        // 50% of 255 ≈ 127.5 → rounds to 128.
        let hits = ColorScanner.scan("rgb(50%, 50%, 50%)")
        let c = hits.first?.color
        XCTAssertEqual(c?.r, 128)
        XCTAssertEqual(c?.g, 128)
        XCTAssertEqual(c?.b, 128)
    }

    func test_rgba_alphaFloat() {
        let hits = ColorScanner.scan("rgba(255, 0, 0, 0.5)")
        XCTAssertEqual(hits.first?.color, .init(r: 255, g: 0, b: 0, a: 128))
    }

    func test_rgba_alphaPercent() {
        let hits = ColorScanner.scan("rgba(255, 0, 0, 50%)")
        XCTAssertEqual(hits.first?.color.a, 128)
    }

    func test_rgb_modernSlashAlpha() {
        // CSS Color 4: `rgb(r g b / a)` — accept slash separator.
        let hits = ColorScanner.scan("rgb(10 20 30 / 0.5)")
        XCTAssertEqual(hits.first?.color, .init(r: 10, g: 20, b: 30, a: 128))
    }

    func test_rgb_missingClose_rejected() {
        XCTAssertEqual(ColorScanner.scan("rgb(1, 2, 3").count, 0)
    }

    func test_rgb_acceptsFourArgsModernCSS() {
        // CSS Color 4: `rgb()` accepts an optional 4th alpha arg
        // — same shape as `rgba()`. Both must parse identically.
        let modern = ColorScanner.scan("rgb(10, 20, 30, 0.5)")
        let legacy = ColorScanner.scan("rgba(10, 20, 30, 0.5)")
        XCTAssertEqual(modern.first?.color, legacy.first?.color)
    }

    func test_rgb_twoArgs_rejected() {
        // Too few — 2 args shouldn't match either form.
        XCTAssertEqual(ColorScanner.scan("rgb(1, 2)").count, 0)
    }

    func test_rgba_threeArgs_rejected() {
        // `rgba` requires the alpha arg.
        XCTAssertEqual(ColorScanner.scan("rgba(1, 2, 3)").count, 0)
    }

    // MARK: - hsl / hsla

    func test_hsl_red() {
        let hits = ColorScanner.scan("hsl(0, 100%, 50%)")
        XCTAssertEqual(hits.first?.color, .init(r: 255, g: 0, b: 0, a: 0xFF))
    }

    func test_hsl_green() {
        let hits = ColorScanner.scan("hsl(120, 100%, 50%)")
        XCTAssertEqual(hits.first?.color, .init(r: 0, g: 255, b: 0, a: 0xFF))
    }

    func test_hsl_blue() {
        let hits = ColorScanner.scan("hsl(240, 100%, 50%)")
        XCTAssertEqual(hits.first?.color, .init(r: 0, g: 0, b: 255, a: 0xFF))
    }

    func test_hsla_alpha() {
        let hits = ColorScanner.scan("hsla(0, 100%, 50%, 0.5)")
        XCTAssertEqual(hits.first?.color.a, 128)
    }

    func test_hsl_hueDegSuffix() {
        let plain = ColorScanner.scan("hsl(180, 100%, 50%)")
        let suffixed = ColorScanner.scan("hsl(180deg, 100%, 50%)")
        XCTAssertEqual(plain.first?.color, suffixed.first?.color)
    }

    // MARK: - Multi-match / boundaries

    func test_multipleMatches_inOrder() {
        let text = "fg: #ff0000; bg: rgb(0, 255, 0);"
        let hits = ColorScanner.scan(text)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].color, .init(r: 255, g: 0, b: 0, a: 0xFF))
        XCTAssertEqual(hits[1].color, .init(r: 0, g: 255, b: 0, a: 0xFF))
    }

    func test_byteRanges_areUTF8Offsets() {
        // The leading "你好" is 6 UTF-8 bytes; "#fff" starts at 6.
        let text = "你好#fff"
        let hits = ColorScanner.scan(text)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].byteRange, 6..<10)
    }

    func test_emptyInput() {
        XCTAssertEqual(ColorScanner.scan("").count, 0)
    }

    func test_noiseInput() {
        XCTAssertEqual(ColorScanner.scan("just plain text").count, 0)
    }

    // MARK: - Luma sanity

    func test_luma_blackIsZero() {
        XCTAssertEqual(ScribeRGBA(r: 0, g: 0, b: 0, a: 255).luma, 0, accuracy: 0.001)
    }

    func test_luma_whiteIsOne() {
        XCTAssertEqual(ScribeRGBA(r: 255, g: 255, b: 255, a: 255).luma, 1, accuracy: 0.001)
    }

    func test_sciBGR_packing() {
        // Red = (255, 0, 0); BGR int should be 0x0000FF.
        let red = ScribeRGBA(r: 255, g: 0, b: 0, a: 255)
        XCTAssertEqual(red.sciBGR, 0x0000FF)
        // Blue = (0, 0, 255); BGR int should be 0xFF0000.
        let blue = ScribeRGBA(r: 0, g: 0, b: 255, a: 255)
        XCTAssertEqual(blue.sciBGR, 0xFF0000)
    }
}
