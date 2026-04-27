//
//  TextFormat.swift
//  Encoding + line-ending detection and conversion.
//
//  Mirrors ndd's Encode.cpp heuristic — BOM → strict UTF-8 → GB18030 → fallback —
//  but rewritten in Swift, Qt-free. Adds Big5 and Shift-JIS as additional
//  candidates. Line endings are normalised to LF in memory and restored on save.
//

import Foundation

enum TextEncoding: String, CaseIterable, Identifiable {
    case utf8 = "UTF-8"
    case utf8WithBOM = "UTF-8 (BOM)"
    case utf16LE = "UTF-16 LE"
    case utf16BE = "UTF-16 BE"
    case gb18030 = "GB18030 / GBK"
    case big5 = "Big5"
    case shiftJIS = "Shift-JIS"
    case eucKR = "EUC-KR"
    case ascii = "ASCII"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var hasBOM: Bool {
        switch self {
        case .utf8WithBOM, .utf16LE, .utf16BE: return true
        default: return false
        }
    }

    var bomBytes: [UInt8] {
        switch self {
        case .utf8WithBOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        default: return []
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8WithBOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .gb18030: return Self.cfEncoding(.GB_18030_2000)
        case .big5: return Self.cfEncoding(.big5)
        case .shiftJIS: return .shiftJIS
        case .eucKR: return Self.cfEncoding(.EUC_KR)
        case .ascii: return .ascii
        }
    }

    private static func cfEncoding(_ e: CFStringEncodings) -> String.Encoding {
        let ns = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue))
        return String.Encoding(rawValue: ns)
    }
}

enum LineEnding: String, CaseIterable, Identifiable {
    case lf = "Unix (LF)"
    case crlf = "Windows (CRLF)"
    case cr = "Classic Mac (CR)"

    var id: String { rawValue }
    var short: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }

    var rawSequence: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }
}

struct DetectedTextFormat {
    var encoding: TextEncoding
    var lineEnding: LineEnding
    /// Text already normalised to LF. Empty string is a valid result.
    var text: String
}

enum TextFormatDetector {

    // MARK: - Public

    /// Decode bytes into text plus recovered encoding + line ending.
    /// Always returns something — falls back to lossy UTF-8 when nothing
    /// decodes cleanly.
    static func decode(data: Data) -> DetectedTextFormat {
        let (encoding, payload) = sniffEncoding(in: data)
        let raw = String(data: payload, encoding: encoding.stringEncoding)
            ?? String(decoding: payload, as: UTF8.self)
        let ending = detectLineEnding(in: raw)
        return DetectedTextFormat(encoding: encoding,
                                  lineEnding: ending,
                                  text: normalize(raw))
    }

    /// Encode text for writing — applies the chosen line ending and prepends a BOM
    /// if the encoding requires one.
    static func encode(_ text: String,
                       encoding: TextEncoding,
                       lineEnding: LineEnding) -> Data? {
        let denormalised = denormalize(text, lineEnding: lineEnding)
        guard var payload = denormalised.data(using: encoding.stringEncoding) else {
            return nil
        }
        if encoding.hasBOM {
            payload = Data(encoding.bomBytes) + payload
        }
        return payload
    }

    /// Strip the BOM bytes (if any) that match `encoding`. Used when re-decoding
    /// the same on-disk file with a user-chosen encoding.
    static func stripBOM(_ data: Data, for encoding: TextEncoding) -> Data {
        let bom = encoding.bomBytes
        guard !bom.isEmpty,
              data.count >= bom.count,
              [UInt8](data.prefix(bom.count)) == bom else {
            return data
        }
        return data.dropFirst(bom.count)
    }

    // MARK: - Encoding sniffer

    private static func sniffEncoding(in data: Data) -> (TextEncoding, Data) {
        let bytes = [UInt8](data.prefix(4))

        // BOM checks
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return (.utf8WithBOM, data.dropFirst(3))
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return (.utf16LE, data.dropFirst(2))
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return (.utf16BE, data.dropFirst(2))
        }

        // No BOM — ASCII fast path
        if data.allSatisfy({ $0 < 0x80 }) {
            return (.utf8, data)
        }

        // Strict UTF-8 verification (no replacement characters allowed).
        if isValidUTF8(data) {
            return (.utf8, data)
        }

        // GB18030 (covers GBK/GB2312).
        if String(data: data, encoding: TextEncoding.gb18030.stringEncoding) != nil {
            return (.gb18030, data)
        }

        // Big5
        if String(data: data, encoding: TextEncoding.big5.stringEncoding) != nil {
            return (.big5, data)
        }

        // Shift-JIS
        if String(data: data, encoding: .shiftJIS) != nil {
            return (.shiftJIS, data)
        }

        // Last resort: pretend UTF-8 and let the decoder substitute.
        return (.utf8, data)
    }

    /// Strict UTF-8 byte sequence check (RFC 3629). Rejects overlong forms
    /// implicitly because we only validate length+continuation bits.
    private static func isValidUTF8(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            let need: Int
            if b < 0x80 { i += 1; continue }
            else if b & 0xE0 == 0xC0 { need = 1 }
            else if b & 0xF0 == 0xE0 { need = 2 }
            else if b & 0xF8 == 0xF0 { need = 3 }
            else { return false }
            guard i + need < bytes.count else { return false }
            for j in 1...need where bytes[i + j] & 0xC0 != 0x80 {
                return false
            }
            i += need + 1
        }
        return true
    }

    // MARK: - Line ending

    static func detectLineEnding(in text: String) -> LineEnding {
        // Scan up to ~16 KB of unicode scalars. We must use UnicodeScalar (not
        // Character) because Swift collapses "\r\n" into a single grapheme,
        // which would hide every CRLF from a Character-based loop.
        let scanLimit = 16 * 1024
        var scalars = Array(text.unicodeScalars)
        if scalars.count > scanLimit { scalars = Array(scalars.prefix(scanLimit)) }
        var crlf = 0, cr = 0, lf = 0
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "\r" {
                if i + 1 < scalars.count && scalars[i + 1] == "\n" {
                    crlf += 1
                    i += 2
                    continue
                }
                cr += 1
            } else if s == "\n" {
                lf += 1
            }
            i += 1
        }
        if crlf > 0 && crlf >= max(lf, cr) { return .crlf }
        if cr > lf { return .cr }
        return .lf
    }

    static func normalize(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\r\n", with: "\n")
        out = out.replacingOccurrences(of: "\r", with: "\n")
        return out
    }

    static func denormalize(_ text: String, lineEnding: LineEnding) -> String {
        switch lineEnding {
        case .lf: return text
        case .crlf: return text.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: return text.replacingOccurrences(of: "\n", with: "\r")
        }
    }
}
