//
//  Generators.swift
//  Phase 41b — small text generators that insert at the caret.
//  Five flavours: UUID / Lorem / Password / Timestamp / QR.
//
//  Design choices
//    • Each generator is a pure (or pure-ish — Password/UUID need
//      randomness) function returning a `String`. The caller funnels
//      the result through `findState.commands.send(.insertSnippet(_))`
//      so multi-caret workflows pick up the insertion for free.
//    • Randomness uses `SystemRandomNumberGenerator` which on
//      darwin maps to `arc4random`. Good enough for ad-hoc dev
//      passwords / nonces; deliberately NOT positioned as a
//      crypto-grade tool — Password.generate is for the "I need a
//      throwaway dev password" use case.
//    • QR codes are rendered as ASCII art using two Unicode block
//      glyphs (▀ ▄) so each character row holds two scan rows.
//      That keeps the inserted block readable when pasted into
//      issue trackers / chat / READMEs without ever touching disk.
//

import Foundation
#if canImport(CoreImage)
import CoreImage
#endif

enum Generators {

    enum GenError: Error, Equatable {
        case invalid(String)
    }

    // MARK: - UUID v4

    /// Random UUID. Lowercase by default — that's the form
    /// JSON / database GUID columns / npm-package examples reach
    /// for, and it's the form the Foundation `UUID` type prints
    /// uppercase, so we lower it once at the boundary.
    static func uuidV4(uppercase: Bool = false) -> String {
        let s = UUID().uuidString
        return uppercase ? s : s.lowercased()
    }

    // MARK: - Lorem ipsum

    /// Canonical 19-word English-Latin pool. The classic incipit
    /// is the first sentence; subsequent words cycle deterministic-
    /// ally via a seeded shuffle so a "give me 50 words" request
    /// reproduces the same output across runs (regression-friendly,
    /// and good for diffs).
    private static let loremPool: [String] = [
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur",
        "adipiscing", "elit", "sed", "do", "eiusmod", "tempor",
        "incididunt", "ut", "labore", "et", "dolore", "magna",
        "aliqua", "ut", "enim", "ad", "minim", "veniam", "quis",
        "nostrud", "exercitation", "ullamco", "laboris", "nisi",
        "ut", "aliquip", "ex", "ea", "commodo", "consequat",
        "duis", "aute", "irure", "dolor", "in", "reprehenderit",
        "in", "voluptate", "velit", "esse", "cillum", "dolore",
        "eu", "fugiat", "nulla", "pariatur", "excepteur", "sint",
        "occaecat", "cupidatat", "non", "proident", "sunt", "in",
        "culpa", "qui", "officia", "deserunt", "mollit", "anim",
        "id", "est", "laborum"
    ]

    /// Generate `wordCount` words of Lorem Ipsum. The first word
    /// is always capitalised and the output ends with a period so
    /// pasting it into a UI mock looks like a real sentence rather
    /// than a tokenizer dump.
    static func lorem(wordCount: Int) -> String {
        let n = max(0, wordCount)
        if n == 0 { return "" }
        var words: [String] = []
        words.reserveCapacity(n)
        // Always start with the canonical incipit so the output
        // reads like Lorem Ipsum on first glance.
        let preamble = ["Lorem", "ipsum", "dolor", "sit", "amet"]
        for i in 0..<min(n, preamble.count) {
            words.append(preamble[i])
        }
        // Fill the remainder by cycling the pool — deterministic so
        // tests have something stable to assert against.
        var idx = 0
        while words.count < n {
            words.append(loremPool[idx % loremPool.count])
            idx += 1
        }
        var joined = words.joined(separator: " ")
        // Capitalise first letter (preamble already does, but if
        // wordCount was 0...preamble.count we still want it sure).
        if let first = joined.first, first.isLowercase {
            joined = String(first.uppercased()) + joined.dropFirst()
        }
        joined.append(".")
        return joined
    }

    // MARK: - Password

    struct PasswordOptions: Equatable {
        var length: Int = 16
        var includeUppercase: Bool = true
        var includeLowercase: Bool = true
        var includeDigits: Bool = true
        var includeSymbols: Bool = false
    }

    /// Generate a password of `options.length`. At least one
    /// character class must be selected — caller should validate
    /// before invoking; we throw `.invalid` if all four flags are
    /// false to make accidental empty-alphabet bugs surface early
    /// rather than silently produce empty strings.
    static func password(options: PasswordOptions) throws -> String {
        var alphabet: [Character] = []
        if options.includeLowercase { alphabet.append(contentsOf: "abcdefghijklmnopqrstuvwxyz") }
        if options.includeUppercase { alphabet.append(contentsOf: "ABCDEFGHIJKLMNOPQRSTUVWXYZ") }
        if options.includeDigits    { alphabet.append(contentsOf: "0123456789") }
        if options.includeSymbols   { alphabet.append(contentsOf: "!@#$%^&*()-_=+[]{};:,.<>/?") }
        guard !alphabet.isEmpty else {
            throw GenError.invalid("Password requires at least one character class")
        }
        let length = max(1, options.length)
        var rng = SystemRandomNumberGenerator()
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            let idx = Int(rng.next(upperBound: UInt64(alphabet.count)))
            out.append(alphabet[idx])
        }
        return out
    }

    // MARK: - Timestamp

    enum TimestampFormat: String, CaseIterable {
        case iso8601
        case iso8601Compact   // 2026-04-30T15:42:00Z
        case unixSeconds
        case unixMillis
        case rfc2822
        case yyyymmdd         // 2026-04-30
        case yyyymmddHHMMSS   // 2026-04-30 15:42:00
    }

    /// Now-stamp in the requested format. Date is always taken from
    /// `Date()` — callers wanting a fixed timestamp for tests pass
    /// `now` explicitly.
    static func timestamp(format: TimestampFormat,
                          now: Date = Date(),
                          timezone: TimeZone = .current) -> String {
        switch format {
        case .iso8601:
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime,
                               .withFractionalSeconds]
            f.timeZone = timezone
            return f.string(from: now)
        case .iso8601Compact:
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            f.timeZone = timezone
            return f.string(from: now)
        case .unixSeconds:
            return String(Int64(now.timeIntervalSince1970))
        case .unixMillis:
            return String(Int64(now.timeIntervalSince1970 * 1000))
        case .rfc2822:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timezone
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return f.string(from: now)
        case .yyyymmdd:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timezone
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: now)
        case .yyyymmddHHMMSS:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timezone
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.string(from: now)
        }
    }

    // MARK: - QR (ASCII art via Core Image)

    /// Render a QR code for `payload` as ASCII art using the upper-
    /// half block glyph `▀` (each character row encodes two scan
    /// rows: foreground top means white, foreground bottom means
    /// white, etc.). Falls back to a plain `█` grid if the half-block
    /// substitution would lose the bottom row (odd row count) so
    /// the readout always ends on a clean rectangle.
    ///
    /// CoreImage's `CIQRCodeGenerator` does the heavy lifting —
    /// versioning, error correction, mask selection. We just sample
    /// the resulting bitmap.
    ///
    /// Throws `.invalid` if the payload is empty or if Core Image
    /// fails to render (typically: payload too long for any QR
    /// version at the requested error correction level).
    static func qrASCII(payload: String,
                        errorCorrection: QRErrorCorrection = .medium)
        throws -> String
    {
        guard !payload.isEmpty else {
            throw GenError.invalid("QR payload is empty")
        }
        #if canImport(CoreImage)
        guard let data = payload.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else {
            throw GenError.invalid("Core Image filter unavailable")
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(errorCorrection.rawValue, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else {
            throw GenError.invalid("QR generator returned no image (payload too long?)")
        }
        let context = CIContext(options: nil)
        let extent = output.extent
        guard let cg = context.createCGImage(output, from: extent) else {
            throw GenError.invalid("QR rasterisation failed")
        }
        return rasterToASCII(cg)
        #else
        throw GenError.invalid("Core Image not available on this platform")
        #endif
    }

    enum QRErrorCorrection: String {
        case low       = "L"   // ~7% recovery
        case medium    = "M"   // ~15%
        case quartile  = "Q"   // ~25%
        case high      = "H"   // ~30%
    }

    #if canImport(CoreImage)
    /// Sample a CGImage's modules into a bool grid, then fold into
    /// half-block characters. CIQRCodeGenerator emits 1 px per
    /// module so we can read directly without resampling.
    private static func rasterToASCII(_ cg: CGImage) -> String {
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return "" }
        // Render into a known 8-bit grayscale buffer so each pixel
        // is one byte we can read straight away. CIQRCodeGenerator
        // already emits black-on-white, so any byte < 128 is a
        // module ("on").
        let bytesPerRow = w
        var pixels = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &pixels,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return "" }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Add a 1-module quiet zone so QR readers don't need to
        // hunt for the boundary against pasted background text.
        let quiet = 1
        let totalW = w + 2 * quiet
        let totalH = h + 2 * quiet
        // 2D bool grid: true = dark.
        var grid = [[Bool]](repeating: [Bool](repeating: false, count: totalW),
                            count: totalH)
        for y in 0..<h {
            for x in 0..<w {
                // Core Image's image origin is bottom-left; flip Y
                // so row 0 of the grid is the *top* of the QR.
                let row = (h - 1 - y) + quiet
                let col = x + quiet
                grid[row][col] = pixels[y * bytesPerRow + x] < 128
            }
        }

        // Fold into half-block characters: two scan rows per text row.
        var lines: [String] = []
        var r = 0
        while r < totalH {
            var line = ""
            line.reserveCapacity(totalW)
            for c in 0..<totalW {
                let top = grid[r][c]
                let bottom = (r + 1 < totalH) ? grid[r + 1][c] : false
                switch (top, bottom) {
                case (false, false): line.append(" ")
                case (true,  false): line.append("▀")
                case (false, true ): line.append("▄")
                case (true,  true ): line.append("█")
                }
            }
            lines.append(line)
            r += 2
        }
        return lines.joined(separator: "\n")
    }
    #endif
}
