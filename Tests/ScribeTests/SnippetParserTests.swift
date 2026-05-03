//
//  SnippetParserTests.swift
//  Phase 63 — locks down `SnippetParser` so the editor side can
//  rely on:
//    1. Bodies without any `$N` token round-trip verbatim, and
//       the output carries a single synthetic `$0` stop at the
//       tail (zero-width).
//    2. `$N`, `${N}`, `${N:default}` are all recognised and
//       contribute the right plainText slice + UTF-16 range.
//    3. `\$` escapes a literal dollar (and pass-through `$abc`
//       doesn't parse as a token).
//    4. Visit order is ascending non-zero indices, then `$0`.
//    5. Duplicate indices register as one stop (the first); the
//       repeated default text still lands in plainText so the
//       buffer matches what the user wrote.
//    6. Non-ASCII default text reports UTF-16 length, not byte
//       count — callers translate to UTF-8 byte offsets when they
//       embed the snippet into Scintilla.
//

import XCTest
@testable import Scribe

final class SnippetParserTests: XCTestCase {

    // MARK: - No-token bodies

    func test_emptyBody_synthesisesTerminalStop() {
        let parsed = SnippetParser.parse("")
        XCTAssertEqual(parsed.plainText, "")
        XCTAssertEqual(parsed.stops.count, 1)
        XCTAssertEqual(parsed.stops[0].index, 0)
        XCTAssertEqual(parsed.stops[0].location, 0)
        XCTAssertEqual(parsed.stops[0].length, 0)
    }

    func test_bodyWithoutTokens_returnsBodyAndTrailingZeroStop() {
        let parsed = SnippetParser.parse("hello world")
        XCTAssertEqual(parsed.plainText, "hello world")
        XCTAssertEqual(parsed.stops.count, 1)
        XCTAssertEqual(parsed.stops[0].index, 0)
        XCTAssertEqual(parsed.stops[0].location, "hello world".utf16.count)
        XCTAssertEqual(parsed.stops[0].length, 0)
    }

    // MARK: - Token shapes

    func test_bareDollarN_zeroWidthStop() {
        let parsed = SnippetParser.parse("foo $1 bar")
        XCTAssertEqual(parsed.plainText, "foo  bar")
        // Visit order: $1, then synthetic $0 at the end.
        XCTAssertEqual(parsed.stops.map(\.index), [1, 0])
        XCTAssertEqual(parsed.stops[0].location, 4) // "foo "
        XCTAssertEqual(parsed.stops[0].length, 0)
        XCTAssertEqual(parsed.stops[1].location, parsed.plainText.utf16.count)
    }

    func test_bracedDollarN_equalsBareDollar() {
        let bare = SnippetParser.parse("a$2b")
        let braced = SnippetParser.parse("a${2}b")
        XCTAssertEqual(bare, braced,
                       "${N} and $N must produce the same parse")
    }

    func test_bracedWithDefault_keepsDefaultInPlainText() {
        let parsed = SnippetParser.parse("call(${1:arg})")
        XCTAssertEqual(parsed.plainText, "call(arg)")
        XCTAssertEqual(parsed.stops.first?.index, 1)
        XCTAssertEqual(parsed.stops.first?.location, 5)   // after "call("
        XCTAssertEqual(parsed.stops.first?.length, 3)     // "arg"
    }

    func test_emptyDefault_isZeroWidthStop() {
        let parsed = SnippetParser.parse("[${1:}]")
        XCTAssertEqual(parsed.plainText, "[]")
        XCTAssertEqual(parsed.stops.first?.length, 0)
        XCTAssertEqual(parsed.stops.first?.location, 1)
    }

    // MARK: - Visit order + duplicates

    func test_multipleStops_visitOrderIsAscendingThenZero() {
        let parsed = SnippetParser.parse("$3 $1 $2 $0 tail")
        XCTAssertEqual(parsed.stops.map(\.index), [1, 2, 3, 0])
    }

    func test_duplicateIndex_keepsFirstStopOnly() {
        // Both `${1:foo}` occurrences contribute "foo" to plainText
        // (visible to the user), but only the first registers as
        // a tab stop (mirrors are deferred to a v2 phase).
        let parsed = SnippetParser.parse("${1:foo}-${1:foo}")
        XCTAssertEqual(parsed.plainText, "foo-foo")
        XCTAssertEqual(parsed.stops.map(\.index), [1, 0])
        XCTAssertEqual(parsed.stops[0].location, 0)
        XCTAssertEqual(parsed.stops[0].length, 3)
    }

    func test_duplicateZero_collapsesToOne() {
        let parsed = SnippetParser.parse("$0 $0")
        // First $0 is the explicit terminal stop; the second
        // dollar-zero leaves no second stop entry.
        XCTAssertEqual(parsed.stops.count, 1)
        XCTAssertEqual(parsed.stops.first?.index, 0)
        XCTAssertEqual(parsed.stops.first?.location, 0)
    }

    // MARK: - Escapes + pass-through

    func test_escapedDollar_isLiteral() {
        let parsed = SnippetParser.parse("price: \\$10 ${1:tax}")
        XCTAssertEqual(parsed.plainText, "price: $10 tax")
        XCTAssertEqual(parsed.stops.first?.index, 1)
        // `${1:tax}` lands after "price: $10 ".
        XCTAssertEqual(parsed.stops.first?.location,
                       "price: $10 ".utf16.count)
        XCTAssertEqual(parsed.stops.first?.length, 3)
    }

    func test_unrecognisedDollar_passesThrough() {
        // `$abc` isn't a digit-leading token, so the `$` stays as
        // a literal. No tab stops registered (just synthetic $0).
        let parsed = SnippetParser.parse("$abc")
        XCTAssertEqual(parsed.plainText, "$abc")
        XCTAssertEqual(parsed.stops.count, 1)
        XCTAssertEqual(parsed.stops.first?.index, 0)
    }

    func test_unterminatedBrace_isLiteral() {
        // Unterminated `${1:foo` (no closing `}`) keeps the raw
        // text and registers no stop.
        let parsed = SnippetParser.parse("${1:foo")
        XCTAssertEqual(parsed.plainText, "${1:foo")
        XCTAssertEqual(parsed.stops.count, 1)
        XCTAssertEqual(parsed.stops.first?.index, 0)
    }

    func test_lonelyDollarAtEnd_isLiteral() {
        let parsed = SnippetParser.parse("end$")
        XCTAssertEqual(parsed.plainText, "end$")
        XCTAssertEqual(parsed.stops.count, 1)
    }

    // MARK: - Multi-digit indices

    func test_multiDigitIndex_isParsed() {
        let parsed = SnippetParser.parse("${10:wide}")
        XCTAssertEqual(parsed.plainText, "wide")
        XCTAssertEqual(parsed.stops.first?.index, 10)
        XCTAssertEqual(parsed.stops.first?.length, 4)
    }

    // MARK: - Non-ASCII default text

    func test_chineseDefault_reportsUtf16Length() {
        // "中文" is 2 UTF-16 code units (and 6 UTF-8 bytes — the
        // editor side translates on insert).
        let parsed = SnippetParser.parse("[${1:中文}]")
        XCTAssertEqual(parsed.plainText, "[中文]")
        XCTAssertEqual(parsed.stops.first?.length, 2)
        XCTAssertEqual(parsed.stops.first?.location, 1)
        // Sanity: synthetic $0 lands at the literal-`]` UTF-16 tail.
        XCTAssertEqual(parsed.stops.last?.location,
                       parsed.plainText.utf16.count)
    }

    // MARK: - Equatable / Sendable

    func test_parsedSnippet_isEquatable() {
        let a = SnippetParser.parse("foo $1 bar")
        let b = SnippetParser.parse("foo $1 bar")
        XCTAssertEqual(a, b)
    }
}
