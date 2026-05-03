//
//  SnippetParser.swift
//  Phase 63 — parse VSCode / TextMate-style snippet bodies into a
//  plain-text insertion + a list of tab-stop ranges.
//
//  Syntax we accept (v1)
//
//    $N             — bare numeric placeholder, N >= 0. Zero-width.
//    ${N}           — braced equivalent of `$N`. Same semantics.
//    ${N:default}   — placeholder with default text. `default` is
//                     literal — no nested placeholders in v1.
//    \$             — literal dollar sign (escape). Escapes any
//                     other char pass through as the two-char
//                     sequence.
//
//  Semantics
//
//    * `$0` is the *terminal* tab stop: after the user visits it
//      (or Tab cycles past the last non-zero stop), the session
//      ends with the caret parked there. If the body omits $0, we
//      synthesize one at the end of the inserted text.
//    * Non-zero stops are visited in ascending numeric order. Ties
//      (two `${1}` occurrences) are a v2 feature (mirrors); v1
//      only honours the first.
//    * Every stop's `range` is a UTF-16-code-unit offset into the
//      *plain text* (i.e. the string we're about to insert into the
//      buffer). Callers add the caret's absolute byte position to
//      translate into Scintilla positions.
//
//  Out of scope (deferred to a future Phase 63b if ever wanted)
//
//    * Mirrored stops (`${1}` appearing twice → edit-as-one)
//    * Regex transforms (`${1/foo/bar/g}`)
//    * Variable substitutions (`$CLIPBOARD`, `$TM_FILENAME`, …)
//    * Choice menus (`${1|one,two,three|}`)
//

import Foundation

/// A parsed snippet ready to be inserted into a Scintilla buffer.
struct ParsedSnippet: Equatable, Sendable {
    /// The literal bytes to insert at the caret.
    let plainText: String
    /// Tab stops discovered inside `plainText`, in visit order
    /// (non-zero stops ascending by index, then `$0` at the end).
    /// Ranges are NSRange-style integer pairs against `plainText`
    /// (UTF-16 code units), which matches what `NSString.substring`
    /// and Scintilla's UTF-8 byte math both agree on for pure
    /// ASCII — the common snippet case. For non-ASCII defaults,
    /// callers must re-translate to Scintilla byte positions;
    /// `SnippetSession` handles that.
    let stops: [Stop]

    struct Stop: Equatable, Sendable {
        /// The `N` in `${N:...}`. Zero marks the terminal stop.
        let index: Int
        /// Offset range inside `plainText`, expressed as
        /// `location / length` on UTF-16 code units. Zero-width
        /// for bare `$N` / `${N}`; width of `default` for
        /// `${N:default}`.
        let location: Int
        let length: Int
    }
}

enum SnippetParser {

    /// Parse `body` into plain text + ordered tab stops. Snippets
    /// without any `$`-prefix tokens return `plainText == body` and
    /// `stops.count == 1` (a synthetic `$0` at the end).
    static func parse(_ body: String) -> ParsedSnippet {
        var plain = ""
        var discovered: [(index: Int,
                          location: Int,
                          length: Int,
                          order: Int)] = []
        // We walk the input as a `String.UnicodeScalarView`, which
        // gives us stable one-char advance while preserving the
        // UTF-16 offset we publish to callers.
        let chars = Array(body)
        var i = 0
        // Track how many non-zero stops we've discovered so the
        // two `$0` placeholders (user-specified vs synthesized)
        // don't compete with real stops for visit order.
        var nextOrder = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                // Escaped dollar → literal.
                plain.append("$")
                i += 2
                continue
            }
            guard c == "$" else {
                plain.append(c)
                i += 1
                continue
            }
            // Try to consume a token starting at `i`.
            if let token = consumeToken(chars: chars, startIndex: i) {
                let locationUTF16 = plain.utf16.count
                plain.append(token.defaultText)
                discovered.append((index: token.index,
                                   location: locationUTF16,
                                   length: token.defaultText.utf16.count,
                                   order: nextOrder))
                nextOrder += 1
                i = token.endIndex
                continue
            }
            // Not a recognised token — treat the `$` as literal.
            plain.append("$")
            i += 1
        }

        // Visit order: non-zero stops ascending by index; zero
        // stops last (there should be 0 or 1). Duplicate indices
        // (e.g. two `${1}` occurrences) are a v2 mirrors feature;
        // v1 honours only the first occurrence so the user
        // doesn't Tab to the same logical placeholder twice.
        // Subsequent occurrences still contribute their default
        // text to `plainText` — we simply don't register a stop
        // for them.
        var seen: Set<Int> = []
        var deduped: [(index: Int,
                       location: Int,
                       length: Int,
                       order: Int)] = []
        for stop in discovered where !seen.contains(stop.index) {
            seen.insert(stop.index)
            deduped.append(stop)
        }
        let nonZero = deduped
            .filter { $0.index != 0 }
            .sorted { $0.index < $1.index }
        var zero = deduped.filter { $0.index == 0 }
        if zero.isEmpty {
            let tailLoc = plain.utf16.count
            zero = [(index: 0,
                     location: tailLoc,
                     length: 0,
                     order: nextOrder)]
        }
        let ordered = nonZero + zero
        return ParsedSnippet(
            plainText: plain,
            stops: ordered.map {
                ParsedSnippet.Stop(index: $0.index,
                                   location: $0.location,
                                   length: $0.length)
            }
        )
    }

    // MARK: - Internals

    /// One-token parse result. `endIndex` is the char index right
    /// after the consumed token (so the outer loop can pick up).
    private struct TokenParse {
        let index: Int
        let defaultText: String
        let endIndex: Int
    }

    /// Accepts the chars at `startIndex...` as one of:
    ///   $N          (one or more ASCII digits)
    ///   ${N}
    ///   ${N:default}
    /// Returns `nil` for any other input (including isolated `$`).
    private static func consumeToken(chars: [Character],
                                     startIndex: Int) -> TokenParse? {
        precondition(chars[startIndex] == "$")
        let n = chars.count
        // Peek at the char after `$`.
        guard startIndex + 1 < n else { return nil }
        let next = chars[startIndex + 1]

        if next == "{" {
            // ${N} or ${N:default}
            var j = startIndex + 2
            // Read digits.
            let digitStart = j
            while j < n, chars[j].isASCIIDigit { j += 1 }
            guard j > digitStart else { return nil } // need >= 1 digit
            let indexStr = String(chars[digitStart..<j])
            guard let index = Int(indexStr) else { return nil }

            if j < n, chars[j] == "}" {
                // ${N}
                return TokenParse(index: index,
                                  defaultText: "",
                                  endIndex: j + 1)
            }
            if j < n, chars[j] == ":" {
                // ${N:default} — scan to the matching `}`. We don't
                // support nested placeholders inside default text in
                // v1, so the first `}` at the current depth wins.
                let defaultStart = j + 1
                var k = defaultStart
                while k < n, chars[k] != "}" { k += 1 }
                guard k < n else { return nil } // unterminated ${N:
                let defaultText = String(chars[defaultStart..<k])
                return TokenParse(index: index,
                                  defaultText: defaultText,
                                  endIndex: k + 1)
            }
            return nil
        }
        if next.isASCIIDigit {
            // $N
            var j = startIndex + 1
            while j < n, chars[j].isASCIIDigit { j += 1 }
            let indexStr = String(chars[startIndex + 1..<j])
            guard let index = Int(indexStr) else { return nil }
            return TokenParse(index: index,
                              defaultText: "",
                              endIndex: j)
        }
        return nil
    }
}

private extension Character {
    /// Local helper to avoid bringing `isNumber` (which matches
    /// Unicode digits like ٠-٩) into the parser. Snippet indices
    /// are always ASCII `0...9`.
    var isASCIIDigit: Bool {
        guard let v = asciiValue else { return false }
        return v >= 0x30 && v <= 0x39
    }
}
