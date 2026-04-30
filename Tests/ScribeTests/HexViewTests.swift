//
//  HexViewTests.swift
//  Phase 44 — coverage for the hex-dump formatter.
//

import XCTest
@testable import Scribe

final class HexViewTests: XCTestCase {

    func test_dump_helloWorld() {
        let data = "Hello, World!".data(using: .utf8)!
        let r = HexView.dump(data)
        // Single row covers all 13 bytes. Layout:
        // offset(8) + "  " + 16 byte hex (with split space) + " |" + ascii(16) + "|\n"
        let lines = r.text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 2)        // 1 row + trailing empty
        XCTAssertTrue(lines[0].hasPrefix("00000000"))
        XCTAssertTrue(lines[0].contains("Hello, World!"))
    }

    func test_dump_emptyData() {
        let r = HexView.dump(Data())
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(r.originalByteCount, 0)
        XCTAssertFalse(r.truncated)
    }

    func test_dump_unprintableShowsDot() {
        let data = Data([0x00, 0x01, 0x02, 0xFF])
        let r = HexView.dump(data)
        // ASCII gutter for these four bytes should all be '.'.
        XCTAssertTrue(r.text.contains("|...."))
    }

    func test_dump_offsetIncrementsByRow() {
        // 32 bytes = two full 16-byte rows.
        let data = Data(repeating: 0x41, count: 32)
        let r = HexView.dump(data)
        let lines = r.text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("00000000"))
        XCTAssertTrue(lines[1].hasPrefix("00000010"))
    }

    func test_dump_bytesPerRowOverride() {
        let data = Data(repeating: 0xAB, count: 8)
        // Forcing 4 bytes per row should yield 2 rows.
        let r = HexView.dump(data, bytesPerRow: 4)
        let lines = r.text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3)        // 2 rows + trailing empty
    }

    func test_dump_truncationFlagged() {
        let data = Data(repeating: 0x00, count: 100)
        let r = HexView.dump(data, maxBytes: 16)
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.dumpedByteCount, 16)
        XCTAssertEqual(r.originalByteCount, 100)
    }

    func test_dump_lastRowPadsAscii() {
        // 5 bytes — last row is partial; ASCII gutter must still be
        // 16 chars wide so the | borders align across rows.
        let data = Data([0x41, 0x42, 0x43, 0x44, 0x45])
        let r = HexView.dump(data)
        let lines = r.text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let row = lines.first else { XCTFail("no row"); return }
        // Find ASCII gutter — between the first '|' and last '|'.
        guard let openBar = row.firstIndex(of: "|"),
              let closeBar = row.lastIndex(of: "|"),
              openBar != closeBar else {
            XCTFail("no ascii gutter")
            return
        }
        let ascii = row[row.index(after: openBar)..<closeBar]
        XCTAssertEqual(ascii.count, 16)
    }

    // MARK: - byte/offset helpers

    func test_formatOffset_paddedToEightHex() {
        XCTAssertEqual(HexView.formatOffset(0), "00000000")
        XCTAssertEqual(HexView.formatOffset(0x1A), "0000001a")
        XCTAssertEqual(HexView.formatOffset(0xDEADBEEF), "deadbeef")
    }

    func test_formatByte_lowercaseTwoHex() {
        XCTAssertEqual(HexView.formatByte(0x00), "00")
        XCTAssertEqual(HexView.formatByte(0xAB), "ab")
        XCTAssertEqual(HexView.formatByte(0xFF), "ff")
    }

    func test_printableAscii_boundaries() {
        XCTAssertEqual(HexView.printableASCII(0x1F), ".")
        XCTAssertEqual(HexView.printableASCII(0x20), " ")
        XCTAssertEqual(HexView.printableASCII(0x7E), "~")
        XCTAssertEqual(HexView.printableASCII(0x7F), ".")
    }
}
