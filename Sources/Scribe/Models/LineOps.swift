//
//  LineOps.swift
//  Phase 41d — line-level transforms (dedupe, sort, reverse, trim,
//  Tab ↔ Space, case toggles). All are pure: input string → output
//  string. Newlines are preserved as authored: each operation
//  detects whether the input uses LF / CRLF / CR and re-emits the
//  same separator. A trailing newline on the input is preserved on
//  the output too (so `dedupe` doesn't silently drop it).
//
//  Why a dedicated module
//    Line transforms compose with the existing TextTransformAction
//    pipeline (right-click ▸ Transform / Tools ▸ Line Ops / Command
//    Palette) but they are *fundamentally* line-oriented, not
//    byte-oriented like base64 / urlencode / hash, and unlike
//    those they preserve a meaningful "row" structure. Keeping
//    them in their own enum + namespace makes the intent
//    obvious and gives the test target one place to look.
//

import Foundation

enum LineOps {

    // MARK: - Public entry points

    /// Drop consecutive *and* non-consecutive duplicates while
    /// preserving the order of first occurrence. Comparison is
    /// byte-exact (no trim, no case-fold) so callers can chain
    /// `trimTrailingWhitespace` / `lowercased` first if they want
    /// fuzzier dedupe.
    static func deduplicate(_ text: String) -> String {
        let (lines, sep, trailing) = split(text)
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            if seen.insert(line).inserted {
                out.append(line)
            }
        }
        return rejoin(out, separator: sep, trailing: trailing)
    }

    /// Drop empty lines (length 0 *and* whitespace-only).
    static func dropBlankLines(_ text: String) -> String {
        let (lines, sep, trailing) = split(text)
        let kept = lines.filter { !$0.allSatisfy(\.isWhitespace) }
        return rejoin(kept, separator: sep, trailing: trailing)
    }

    /// Reverse line order. Trailing newline (if any) stays at the end.
    static func reverse(_ text: String) -> String {
        let (lines, sep, trailing) = split(text)
        return rejoin(Array(lines.reversed()), separator: sep, trailing: trailing)
    }

    /// Strip trailing whitespace (spaces, tabs, \v) per line.
    /// Newlines themselves stay; only horizontal whitespace at
    /// end-of-line is removed.
    static func trimTrailingWhitespace(_ text: String) -> String {
        let (lines, sep, trailing) = split(text)
        let trimmed = lines.map { line -> String in
            var slice = Substring(line)
            while let last = slice.last,
                  last == " " || last == "\t" || last == "\u{0B}" {
                slice = slice.dropLast()
            }
            return String(slice)
        }
        return rejoin(trimmed, separator: sep, trailing: trailing)
    }

    /// Convert leading runs of `\t` into `tabWidth` spaces. Only
    /// indentation is touched — tabs in the middle of a line are
    /// left alone (think TSV data).
    static func tabsToSpaces(_ text: String, tabWidth: Int = 4) -> String {
        let (lines, sep, trailing) = split(text)
        let pad = String(repeating: " ", count: max(0, tabWidth))
        let converted = lines.map { line -> String in
            var idx = line.startIndex
            while idx < line.endIndex, line[idx] == "\t" {
                idx = line.index(after: idx)
            }
            let count = line.distance(from: line.startIndex, to: idx)
            return String(repeating: pad, count: count) + line[idx...]
        }
        return rejoin(converted, separator: sep, trailing: trailing)
    }

    /// Convert leading runs of `tabWidth` spaces into `\t`. Mid-line
    /// space sequences are not touched (preserves alignment in
    /// columnar data and column-3 comments).
    static func spacesToTabs(_ text: String, tabWidth: Int = 4) -> String {
        guard tabWidth > 0 else { return text }
        let (lines, sep, trailing) = split(text)
        let converted = lines.map { line -> String in
            var leading = 0
            for ch in line {
                if ch == " " { leading += 1 } else { break }
            }
            let tabs = leading / tabWidth
            let remaining = leading - tabs * tabWidth
            let dropped = line.dropFirst(leading)
            return String(repeating: "\t", count: tabs)
                + String(repeating: " ", count: remaining)
                + dropped
        }
        return rejoin(converted, separator: sep, trailing: trailing)
    }

    // MARK: - Sorting

    enum SortMode: String, Sendable, CaseIterable {
        /// Lexicographic, case-sensitive, locale-independent.
        case lexicographic
        /// Lexicographic but case-insensitive.
        case caseInsensitive
        /// "Natural" comparison — embedded numbers compared as
        /// numbers (`item2` < `item10` < `item11`). Matches the
        /// behaviour Finder uses for filenames.
        case natural
        /// Whole-line interpreted as a number; non-numeric lines
        /// fall back to lexicographic so the operation is total.
        case numeric
        /// Sort by length ascending; ties broken lexicographically
        /// so the output is stable.
        case length
    }

    static func sort(_ text: String,
                     mode: SortMode,
                     descending: Bool = false) -> String {
        let (lines, sep, trailing) = split(text)
        let sorted = lines.sorted { lhs, rhs in
            let result = compare(lhs, rhs, mode: mode)
            return descending ? (result == .orderedDescending)
                              : (result == .orderedAscending)
        }
        return rejoin(sorted, separator: sep, trailing: trailing)
    }

    private static func compare(_ a: String, _ b: String,
                                 mode: SortMode) -> ComparisonResult {
        switch mode {
        case .lexicographic:
            if a == b { return .orderedSame }
            return a < b ? .orderedAscending : .orderedDescending
        case .caseInsensitive:
            return a.compare(b, options: .caseInsensitive)
        case .natural:
            return a.compare(b, options: [.numeric, .caseInsensitive])
        case .numeric:
            let ad = Double(a.trimmingCharacters(in: .whitespaces))
            let bd = Double(b.trimmingCharacters(in: .whitespaces))
            switch (ad, bd) {
            case let (lhs?, rhs?):
                if lhs == rhs { return .orderedSame }
                return lhs < rhs ? .orderedAscending : .orderedDescending
            case (nil, _?): return .orderedDescending  // non-numeric to bottom
            case (_?, nil): return .orderedAscending
            default:        return compare(a, b, mode: .lexicographic)
            }
        case .length:
            if a.count != b.count {
                return a.count < b.count ? .orderedAscending : .orderedDescending
            }
            return compare(a, b, mode: .lexicographic)
        }
    }

    // MARK: - Case toggles

    enum CaseMode: String, Sendable, CaseIterable {
        case lower
        case upper
        /// First letter of every whitespace-separated word
        /// uppercased; rest lowercased.
        case title
        /// First letter of every sentence (after `.!?`) uppercased;
        /// other letters left untouched.
        case sentence
        /// `helloWorld` form — split on non-alphanumerics, lower
        /// first part, capitalise the rest, join with no separator.
        case camel
        /// `hello_world` form — split on non-alphanumerics, lower
        /// every part, join with `_`.
        case snake
        /// `hello-world` form — split on non-alphanumerics, lower
        /// every part, join with `-`.
        case kebab
    }

    static func transformCase(_ text: String, mode: CaseMode) -> String {
        switch mode {
        case .lower:    return text.lowercased()
        case .upper:    return text.uppercased()
        case .title:    return text.capitalized
        case .sentence: return sentenceCase(text)
        case .camel:    return splitTokens(text)
                            .enumerated()
                            .map { i, t in i == 0 ? t.lowercased() : t.capitalized }
                            .joined()
        case .snake:    return splitTokens(text).map { $0.lowercased() }.joined(separator: "_")
        case .kebab:    return splitTokens(text).map { $0.lowercased() }.joined(separator: "-")
        }
    }

    /// Walk char-by-char; uppercase the first letter of each
    /// sentence, leave other characters as-is. Sentence boundary
    /// is `.`, `!`, `?` followed by whitespace.
    private static func sentenceCase(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var sentenceStart = true
        for ch in s {
            if sentenceStart, ch.isLetter {
                out.append(Character(ch.uppercased()))
                sentenceStart = false
            } else {
                out.append(ch)
                if ch == "." || ch == "!" || ch == "?" {
                    sentenceStart = true
                } else if ch.isLetter || ch.isNumber {
                    sentenceStart = false
                }
            }
        }
        return out
    }

    /// Split a string into alphanumeric tokens. Used by camel /
    /// snake / kebab — the boundary set is "anything that isn't
    /// a letter or digit", with one extra rule: a lower→upper
    /// transition (`HTTPHeader` → "HTTP", "Header") also splits.
    private static func splitTokens(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var prev: Character? = nil
        for ch in s {
            if ch.isLetter || ch.isNumber {
                if let p = prev, p.isLowercase, ch.isUppercase, !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            prev = ch
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Internals — line splitting / rejoining

    /// Detected newline separator. We default to LF for empty /
    /// single-line input so a round-trip on "" stays "".
    private enum LineSeparator: String {
        case lf   = "\n"
        case crlf = "\r\n"
        case cr   = "\r"
    }

    private static func split(_ text: String)
        -> (lines: [String], separator: LineSeparator, trailingNewline: Bool) {

        let separator: LineSeparator
        if text.contains("\r\n") {
            separator = .crlf
        } else if text.contains("\r") && !text.contains("\n") {
            separator = .cr
        } else {
            separator = .lf
        }

        let trailing = text.hasSuffix(separator.rawValue)
        // Split on the detected separator. Drop the empty trailing
        // element that arises when text ends with the separator —
        // we'll re-add it via `trailingNewline` at rejoin time so
        // we don't accidentally invent a "final blank line".
        var lines = text.components(separatedBy: separator.rawValue)
        if trailing, let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return (lines, separator, trailing)
    }

    private static func rejoin(_ lines: [String],
                                separator: LineSeparator,
                                trailing: Bool) -> String {
        var out = lines.joined(separator: separator.rawValue)
        if trailing { out.append(separator.rawValue) }
        return out
    }
}
