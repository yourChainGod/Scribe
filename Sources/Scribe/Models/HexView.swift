//
//  HexView.swift
//  Phase 44 — Pure formatter that turns a `Data` blob into the
//  classic three-column hex dump:
//
//      00000000  48 65 6c 6c 6f 2c 20 57  6f 72 6c 64 21 0a 00 ff   Hello, W orld!...
//      00000010  …
//
//  Each row covers 16 bytes; the hex column splits at byte 8 with
//  an extra space for readability; non-printable / non-ASCII bytes
//  appear as `.` in the ASCII column.
//
//  Why a model:
//    The view lives in a SwiftUI sheet that already owns layout,
//    scrolling and selection. Putting the formatter in a pure enum
//    lets us unit-test the dump shape without dragging AppKit in.
//

import Foundation

enum HexView {

    /// Maximum bytes the view-side will request in one call. Beyond
    /// this we trim and surface a "showing first N bytes" banner so
    /// the sheet stays responsive even on giant files.
    static let defaultMaxBytes: Int = 1 << 20   // 1 MiB

    struct DumpResult: Equatable {
        let text: String
        /// True when the source data was longer than the requested
        /// max and the dump was truncated. Banners off this.
        let truncated: Bool
        let originalByteCount: Int
        let dumpedByteCount: Int
    }

    /// Render the classic 16-byte-per-row hex dump.
    /// `bytesPerRow` defaults to 16 (the universal hex-dump shape).
    /// `maxBytes` caps the dump so the sheet doesn't try to render
    /// a 100 MB blob in one go.
    static func dump(_ data: Data,
                     bytesPerRow: Int = 16,
                     maxBytes: Int = defaultMaxBytes) -> DumpResult
    {
        let original = data.count
        let row = max(1, bytesPerRow)
        let limit = max(0, maxBytes)
        let slice = original > limit ? data.prefix(limit) : data

        // Pre-size a String buffer big enough for the typical row
        // — 8 hex offset + space + (3 * row) hex + space + (row+1)
        // ASCII + newline ≈ row * 5 + ~18.
        var out = ""
        out.reserveCapacity(slice.count / row * (row * 5 + 20) + 32)

        var offset = 0
        let total = slice.count
        while offset < total {
            let end = min(offset + row, total)
            // Offset column: 8 lowercase hex digits.
            out.append(formatOffset(offset))
            out.append("  ")

            // Hex column: 2-char per byte, space separated. Pad with
            // 3-char "   " when the last row is short so the ASCII
            // gutter aligns across rows.
            for i in 0..<row {
                if i == row / 2 { out.append(" ") }
                if offset + i < end {
                    let b = slice[slice.startIndex + offset + i]
                    out.append(formatByte(b))
                    out.append(" ")
                } else {
                    out.append("   ")
                }
            }

            out.append(" |")
            for i in 0..<row {
                if offset + i < end {
                    let b = slice[slice.startIndex + offset + i]
                    out.append(printableASCII(b))
                } else {
                    out.append(" ")
                }
            }
            out.append("|\n")

            offset = end
        }

        return DumpResult(text: out,
                          truncated: original > limit,
                          originalByteCount: original,
                          dumpedByteCount: slice.count)
    }

    // MARK: - byte / offset helpers

    private static let hexDigits: [Character] = [
        "0","1","2","3","4","5","6","7",
        "8","9","a","b","c","d","e","f"
    ]

    /// 8-digit lowercase hex — matches `xxd` / `hexdump -C`.
    static func formatOffset(_ offset: Int) -> String {
        var n = offset
        var buf: [Character] = Array(repeating: "0", count: 8)
        var i = 7
        while i >= 0 {
            buf[i] = hexDigits[n & 0xF]
            n >>= 4
            i -= 1
        }
        return String(buf)
    }

    /// 2-digit lowercase hex.
    static func formatByte(_ b: UInt8) -> String {
        var s = ""
        s.append(hexDigits[Int(b >> 4)])
        s.append(hexDigits[Int(b & 0x0F)])
        return s
    }

    /// Map byte → printable ASCII char or '.'.
    /// Printable range: 0x20…0x7E. Everything else (control codes,
    /// high-bit) collapses to '.' so the column stays a clean
    /// fixed-width grid.
    static func printableASCII(_ b: UInt8) -> Character {
        if b >= 0x20 && b <= 0x7E {
            return Character(UnicodeScalar(b))
        }
        return "."
    }
}
