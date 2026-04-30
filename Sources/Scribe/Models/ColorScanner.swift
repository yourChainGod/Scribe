//
//  ColorScanner.swift
//  Phase 41f — recognise CSS-style color literals anywhere in a
//  document so the editor can paint inline swatches behind them.
//
//  Recognised forms (case-insensitive):
//    #RGB     #RGBA     #RRGGBB     #RRGGBBAA
//    rgb(r,g,b)         rgba(r,g,b,a)
//    hsl(h,s%,l%)       hsla(h,s%,l%,a)
//
//  Component grammar (lenient — what people actually paste):
//    • rgb/rgba: r,g,b are 0–255 ints OR 0–100% floats; alpha is
//      0–1 float OR 0–100% percentage. Whitespace anywhere.
//    • hsl/hsla: h is 0–360 (deg suffix optional), s/l are 0–100%,
//      alpha same as rgba.
//
//  Output is a list of UTF-8 byte ranges so the Scintilla
//  indicator wiring can call `SCI_INDICATORFILLRANGE` directly
//  without re-walking the document. Color values ride along as
//  RGBA tuples so the renderer can pack them into the
//  `SC_INDICFLAG_VALUEFORE` payload.
//
//  Scope notes
//    • Named CSS colors (`red`, `dodgerblue`, …) are deliberately
//      OUT for v1 — too many false positives in plain prose.
//    • Mid-identifier matches (`my#fff`, `arrgba`) are skipped via
//      simple word-boundary checks so a swatch never lights up in
//      the middle of a variable name.
//

import Foundation

struct ScribeRGBA: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8

    /// Pack into Scintilla's BGR(A) integer. Scintilla's color
    /// argument is `0xBBGGRR` for `INDICSETFORE` and the same byte
    /// order for the value carried via `SC_INDICFLAG_VALUEFORE`.
    var sciBGR: UInt32 {
        UInt32(b) << 16 | UInt32(g) << 8 | UInt32(r)
    }

    /// Brightness on the perceptual luma scale — used by the
    /// renderer to decide whether the swatch box should be drawn
    /// translucent (light colors) or opaque (dark colors) so the
    /// underlying text stays readable. Range 0…1.
    var luma: Double {
        let R = Double(r) / 255.0
        let G = Double(g) / 255.0
        let B = Double(b) / 255.0
        return 0.2126 * R + 0.7152 * G + 0.0722 * B
    }
}

struct ColorMatch: Equatable {
    /// UTF-8 byte range of the literal in the source string. Half-
    /// open: `[start, end)`.
    let byteRange: Range<Int>
    let color: ScribeRGBA
}

enum ColorScanner {

    /// Scan the entire string for color literals. O(n) — single
    /// pass over the UTF-8 bytes, with bounded look-ahead per
    /// candidate.
    static func scan(_ text: String) -> [ColorMatch] {
        let bytes = Array(text.utf8)
        var out: [ColorMatch] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]

            // `#` hex literal — must follow a non-word character so
            // we don't light up `id="myid#fff"` inside an attribute.
            if b == 0x23 /* # */ {
                if isAtWordBoundary(bytes, position: i),
                   let hit = parseHex(bytes, from: i)
                {
                    out.append(hit)
                    i = hit.byteRange.upperBound
                    continue
                }
            }

            // `rgb` / `rgba` literal — case-insensitive 'r' / 'R'.
            if b == 0x72 || b == 0x52 {
                if isAtWordBoundary(bytes, position: i),
                   let hit = parseRGBFunction(bytes, from: i)
                {
                    out.append(hit)
                    i = hit.byteRange.upperBound
                    continue
                }
            }

            // `hsl` / `hsla` literal — case-insensitive 'h' / 'H'.
            if b == 0x68 || b == 0x48 {
                if isAtWordBoundary(bytes, position: i),
                   let hit = parseHSLFunction(bytes, from: i)
                {
                    out.append(hit)
                    i = hit.byteRange.upperBound
                    continue
                }
            }

            i += 1
        }
        return out
    }

    // MARK: - Word boundary

    /// True when `position` either starts the buffer or sits after
    /// a non-identifier byte. Identifier bytes are letters, digits
    /// and `_` — same set Scintilla uses for default word chars.
    private static func isAtWordBoundary(_ bytes: [UInt8], position: Int) -> Bool {
        if position == 0 { return true }
        let prev = bytes[position - 1]
        return !isIdentifierByte(prev)
    }

    private static func isIdentifierByte(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) ||  // 0-9
        (0x41...0x5A).contains(b) ||  // A-Z
        (0x61...0x7A).contains(b) ||  // a-z
        b == 0x5F                      // _
    }

    private static func isHexByte(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) ||
        (0x41...0x46).contains(b) ||
        (0x61...0x66).contains(b)
    }

    // MARK: - Hex literal

    /// Parse `#RGB` / `#RGBA` / `#RRGGBB` / `#RRGGBBAA` starting at
    /// `start` (which points at the `#`). Returns nil if the run of
    /// hex digits doesn't match one of the four lengths or if the
    /// digit run continues past the longest valid form (e.g. `#fff0fff0a`
    /// — too long, would be ambiguous, so we reject rather than guess).
    private static func parseHex(_ bytes: [UInt8], from start: Int) -> ColorMatch? {
        var j = start + 1
        var digits: [UInt8] = []
        while j < bytes.count, isHexByte(bytes[j]) {
            digits.append(bytes[j])
            j += 1
            if digits.count > 8 { return nil }
        }
        // After the digit run, the next byte must NOT be an
        // identifier byte — `#abcdef0` (7 hex chars in a row) shouldn't
        // get half-matched as `#abcdef`.
        if j < bytes.count, isIdentifierByte(bytes[j]) { return nil }

        let count = digits.count
        guard count == 3 || count == 4 || count == 6 || count == 8 else { return nil }

        let r: UInt8, g: UInt8, b: UInt8, a: UInt8
        switch count {
        case 3:
            r = expand4to8(hexNibble(digits[0]))
            g = expand4to8(hexNibble(digits[1]))
            b = expand4to8(hexNibble(digits[2]))
            a = 0xFF
        case 4:
            r = expand4to8(hexNibble(digits[0]))
            g = expand4to8(hexNibble(digits[1]))
            b = expand4to8(hexNibble(digits[2]))
            a = expand4to8(hexNibble(digits[3]))
        case 6:
            r = (hexNibble(digits[0]) << 4) | hexNibble(digits[1])
            g = (hexNibble(digits[2]) << 4) | hexNibble(digits[3])
            b = (hexNibble(digits[4]) << 4) | hexNibble(digits[5])
            a = 0xFF
        default: // 8
            r = (hexNibble(digits[0]) << 4) | hexNibble(digits[1])
            g = (hexNibble(digits[2]) << 4) | hexNibble(digits[3])
            b = (hexNibble(digits[4]) << 4) | hexNibble(digits[5])
            a = (hexNibble(digits[6]) << 4) | hexNibble(digits[7])
        }
        return ColorMatch(byteRange: start..<j,
                          color: ScribeRGBA(r: r, g: g, b: b, a: a))
    }

    private static func hexNibble(_ b: UInt8) -> UInt8 {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return 0
        }
    }

    private static func expand4to8(_ n: UInt8) -> UInt8 { (n << 4) | n }

    // MARK: - rgb() / rgba()

    private static func parseRGBFunction(_ bytes: [UInt8], from start: Int) -> ColorMatch? {
        // Match "rgb" or "rgba" (case-insensitive), then optional
        // whitespace, then '('.
        let head = readIdentifier(bytes, from: start)
        let lowered = head.lowercased()
        guard lowered == "rgb" || lowered == "rgba" else { return nil }

        var j = start + head.count
        j = skipSpaces(bytes, from: j)
        guard j < bytes.count, bytes[j] == 0x28 /* ( */ else { return nil }
        j += 1
        guard let (components, end) = readComponents(bytes, from: j) else { return nil }

        // CSS Color 4 lets `rgb(r g b / a)` carry alpha too, so
        // accept either 3 or 4 components for `rgb` and require 4
        // for `rgba`. Anything else is rejected so the scanner
        // can't accidentally chain a pair of unrelated literals.
        let count = components.count
        switch lowered {
        case "rgb":
            guard count == 3 || count == 4 else { return nil }
        case "rgba":
            guard count == 4 else { return nil }
        default: return nil
        }

        let r = clampByte(parseRGBComponent(components[0]))
        let g = clampByte(parseRGBComponent(components[1]))
        let b = clampByte(parseRGBComponent(components[2]))
        let a: UInt8 = count == 4
            ? clampByte(parseAlphaComponent(components[3]))
            : 0xFF
        return ColorMatch(byteRange: start..<end,
                          color: ScribeRGBA(r: r, g: g, b: b, a: a))
    }

    /// Component is `N` (0–255), `N%` (0–100% of 255), or float in
    /// either form. Returns 0–255 as a Double.
    private static func parseRGBComponent(_ s: String) -> Double {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") {
            let pct = Double(trimmed.dropLast()) ?? 0
            return pct * 255.0 / 100.0
        }
        return Double(trimmed) ?? 0
    }

    /// Alpha is `0–1` float OR `0–100%`. Returns 0–255 as a Double.
    private static func parseAlphaComponent(_ s: String) -> Double {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") {
            let pct = Double(trimmed.dropLast()) ?? 0
            return pct * 255.0 / 100.0
        }
        let f = Double(trimmed) ?? 0
        return f * 255.0
    }

    // MARK: - hsl() / hsla()

    private static func parseHSLFunction(_ bytes: [UInt8], from start: Int) -> ColorMatch? {
        let head = readIdentifier(bytes, from: start)
        let lowered = head.lowercased()
        guard lowered == "hsl" || lowered == "hsla" else { return nil }

        var j = start + head.count
        j = skipSpaces(bytes, from: j)
        guard j < bytes.count, bytes[j] == 0x28 else { return nil }
        j += 1
        guard let (components, end) = readComponents(bytes, from: j) else { return nil }
        let count = components.count
        switch lowered {
        case "hsl":  guard count == 3 || count == 4 else { return nil }
        case "hsla": guard count == 4 else { return nil }
        default: return nil
        }

        let h = parseHue(components[0])
        let s = parsePercent(components[1])
        let l = parsePercent(components[2])
        let a: Double = count == 4 ? parseAlphaComponent(components[3]) : 255.0

        let rgb = hslToRGB(h: h, s: s, l: l)
        return ColorMatch(byteRange: start..<end,
                          color: ScribeRGBA(r: clampByte(rgb.0),
                                            g: clampByte(rgb.1),
                                            b: clampByte(rgb.2),
                                            a: clampByte(a)))
    }

    /// H in degrees 0–360. Tolerates `deg` / `rad` / `turn` suffixes.
    private static func parseHue(_ s: String) -> Double {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("deg") { t = String(t.dropLast(3)) }
        else if t.hasSuffix("turn") {
            let f = Double(t.dropLast(4)) ?? 0
            return ((f * 360).truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360)
        } else if t.hasSuffix("rad") {
            let f = Double(t.dropLast(3)) ?? 0
            let deg = f * 180.0 / .pi
            return ((deg).truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360)
        }
        let raw = Double(t) ?? 0
        return ((raw).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
    }

    private static func parsePercent(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") { return (Double(t.dropLast()) ?? 0) / 100.0 }
        return (Double(t) ?? 0) / 100.0
    }

    /// Standard CSS HSL to RGB: returns each channel as 0–255 float.
    private static func hslToRGB(h: Double, s: Double, l: Double)
        -> (Double, Double, Double)
    {
        let sat = max(0, min(1, s))
        let light = max(0, min(1, l))
        let c = (1 - abs(2 * light - 1)) * sat
        let hPrime = h / 60.0
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        let m = light - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch hPrime {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default:    (r1, g1, b1) = (c, 0, x)
        }
        return ((r1 + m) * 255, (g1 + m) * 255, (b1 + m) * 255)
    }

    // MARK: - Common helpers

    private static func clampByte(_ d: Double) -> UInt8 {
        if d.isNaN { return 0 }
        if d <= 0 { return 0 }
        if d >= 255 { return 255 }
        return UInt8(d.rounded())
    }

    private static func skipSpaces(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start
        while i < bytes.count, isSpace(bytes[i]) { i += 1 }
        return i
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    /// Read identifier bytes at `start` and return as String.
    /// Letters only — used to match the leading `rgb`/`hsl` token.
    private static func readIdentifier(_ bytes: [UInt8], from start: Int) -> String {
        var j = start
        while j < bytes.count {
            let b = bytes[j]
            if (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) { j += 1 }
            else { break }
        }
        return String(bytes: bytes[start..<j], encoding: .utf8) ?? ""
    }

    /// Read comma- or slash-separated components inside `(...)`
    /// until the matching `)`. Each component is trimmed; the
    /// separator and surrounding whitespace are dropped. The
    /// caller validates the component count.
    ///
    /// `/` is accepted in place of `,` so the modern CSS Color 4
    /// `rgb(r g b / a)` syntax doesn't need a separate code path.
    /// Whitespace-only stretches between numbers (the modern
    /// space-separated form) are also accepted: a transition from
    /// non-whitespace to whitespace inside a component closes it.
    private static func readComponents(_ bytes: [UInt8],
                                       from start: Int)
        -> ([String], Int)?
    {
        var components: [String] = []
        var current: [UInt8] = []
        var i = start
        var sawNonSpace = false
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x29 /* ) */ {
                if !current.isEmpty {
                    components.append(stringify(current))
                }
                return (components, i + 1)
            }
            if b == 0x2C /* , */ || b == 0x2F /* / */ {
                components.append(stringify(current))
                current.removeAll(keepingCapacity: true)
                sawNonSpace = false
                i += 1
                continue
            }
            // Whitespace inside the component: if we've already
            // seen a non-space byte, treat the run as a soft
            // separator (modern syntax). Then skip the run and
            // peek — if the next byte is `,` / `/` / `)`, defer
            // to those branches so we don't double-emit.
            if isSpace(b) {
                if sawNonSpace {
                    let nextIdx = skipSpaces(bytes, from: i)
                    if nextIdx < bytes.count {
                        let nextByte = bytes[nextIdx]
                        if nextByte != 0x2C && nextByte != 0x2F && nextByte != 0x29 {
                            components.append(stringify(current))
                            current.removeAll(keepingCapacity: true)
                            sawNonSpace = false
                        }
                    }
                    i = nextIdx
                    continue
                }
                i += 1
                continue
            }
            current.append(b)
            sawNonSpace = true
            i += 1
        }
        return nil  // unterminated
    }

    private static func stringify(_ b: [UInt8]) -> String {
        let s = String(bytes: b, encoding: .utf8) ?? ""
        return s.trimmingCharacters(in: .whitespaces)
    }
}
