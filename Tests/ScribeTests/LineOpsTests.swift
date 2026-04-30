//
//  LineOpsTests.swift
//  Phase 41d — line operation coverage. Every transform is
//  asserted on:
//    1. canonical happy-path input
//    2. mixed line endings (LF + CRLF + trailing newline)
//    3. boundary inputs (empty string, single-line, all-blank)
//

import XCTest
@testable import Scribe

final class LineOpsTests: XCTestCase {

    // MARK: - Dedupe

    func test_dedupe_preservesFirstOccurrence() {
        XCTAssertEqual(LineOps.deduplicate("a\nb\na\nc\nb"),
                       "a\nb\nc")
    }

    func test_dedupe_preservesTrailingNewline() {
        XCTAssertEqual(LineOps.deduplicate("a\nb\na\n"),
                       "a\nb\n")
    }

    func test_dedupe_preservesCRLF() {
        XCTAssertEqual(LineOps.deduplicate("a\r\nb\r\na"),
                       "a\r\nb")
    }

    func test_dedupe_emptyInput() {
        XCTAssertEqual(LineOps.deduplicate(""), "")
    }

    func test_dedupe_isCaseSensitive() {
        XCTAssertEqual(LineOps.deduplicate("a\nA"), "a\nA")
    }

    // MARK: - Drop blank

    func test_dropBlank_removesEmptyLines() {
        XCTAssertEqual(LineOps.dropBlankLines("a\n\nb\n\n\nc"),
                       "a\nb\nc")
    }

    func test_dropBlank_removesWhitespaceOnlyLines() {
        XCTAssertEqual(LineOps.dropBlankLines("a\n   \n\tb\nc"),
                       "a\n\tb\nc")
    }

    func test_dropBlank_keepsTrailingNewlineIfPresent() {
        XCTAssertEqual(LineOps.dropBlankLines("a\n\nb\n"),
                       "a\nb\n")
    }

    // MARK: - Reverse

    func test_reverse_threeLines() {
        XCTAssertEqual(LineOps.reverse("a\nb\nc"), "c\nb\na")
    }

    func test_reverse_keepsTrailingNewline() {
        XCTAssertEqual(LineOps.reverse("a\nb\nc\n"), "c\nb\na\n")
    }

    func test_reverse_singleLine() {
        XCTAssertEqual(LineOps.reverse("only"), "only")
    }

    // MARK: - Trim trailing whitespace

    func test_trim_stripsSpacesAndTabs() {
        XCTAssertEqual(LineOps.trimTrailingWhitespace("a   \nb\t\t\nc"),
                       "a\nb\nc")
    }

    func test_trim_keepsLeadingIndentation() {
        XCTAssertEqual(LineOps.trimTrailingWhitespace("    a   "),
                       "    a")
    }

    func test_trim_emptyLineStaysEmpty() {
        XCTAssertEqual(LineOps.trimTrailingWhitespace("a\n\nb"),
                       "a\n\nb")
    }

    // MARK: - Tabs ↔ Spaces

    func test_tabsToSpaces_convertsLeadingTabs() {
        XCTAssertEqual(LineOps.tabsToSpaces("\t\thi", tabWidth: 4),
                       "        hi")
    }

    func test_tabsToSpaces_preservesMidLineTabs() {
        XCTAssertEqual(LineOps.tabsToSpaces("a\tb", tabWidth: 4),
                       "a\tb")
    }

    func test_spacesToTabs_convertsLeadingSpaces() {
        XCTAssertEqual(LineOps.spacesToTabs("        hi", tabWidth: 4),
                       "\t\thi")
    }

    func test_spacesToTabs_partialIndentLeavesRemainder() {
        // 6 leading spaces, tabWidth=4 ⇒ one tab + two spaces
        XCTAssertEqual(LineOps.spacesToTabs("      hi", tabWidth: 4),
                       "\t  hi")
    }

    func test_spacesToTabs_preservesMidLineSpaces() {
        XCTAssertEqual(LineOps.spacesToTabs("a    b", tabWidth: 4),
                       "a    b")
    }

    // MARK: - Sort

    func test_sort_lexicographic() {
        XCTAssertEqual(LineOps.sort("c\nA\nb", mode: .lexicographic),
                       "A\nb\nc")
    }

    func test_sort_caseInsensitive() {
        XCTAssertEqual(LineOps.sort("c\nA\nb", mode: .caseInsensitive),
                       "A\nb\nc")
    }

    func test_sort_natural() {
        // The whole point of natural sort: item2 < item10.
        XCTAssertEqual(LineOps.sort("item10\nitem2\nitem1", mode: .natural),
                       "item1\nitem2\nitem10")
    }

    func test_sort_numeric() {
        XCTAssertEqual(LineOps.sort("100\n3\n22", mode: .numeric),
                       "3\n22\n100")
    }

    func test_sort_numericPushesNonNumericToBottom() {
        let result = LineOps.sort("4\nfoo\n1\n2", mode: .numeric)
        // The numeric prefix is sorted ascending; non-numeric line
        // ("foo") sinks to the end.
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "1")
        XCTAssertEqual(lines.last, "foo")
    }

    func test_sort_byLength() {
        XCTAssertEqual(LineOps.sort("abcde\na\nabc", mode: .length),
                       "a\nabc\nabcde")
    }

    func test_sort_descending() {
        XCTAssertEqual(LineOps.sort("a\nb\nc", mode: .lexicographic, descending: true),
                       "c\nb\na")
    }

    // MARK: - Case

    func test_case_lower() {
        XCTAssertEqual(LineOps.transformCase("Hello WORLD", mode: .lower),
                       "hello world")
    }

    func test_case_upper() {
        XCTAssertEqual(LineOps.transformCase("Hello world", mode: .upper),
                       "HELLO WORLD")
    }

    func test_case_title() {
        XCTAssertEqual(LineOps.transformCase("hello world", mode: .title),
                       "Hello World")
    }

    func test_case_sentence() {
        XCTAssertEqual(LineOps.transformCase("hello. how are you? fine!", mode: .sentence),
                       "Hello. How are you? Fine!")
    }

    func test_case_camel() {
        XCTAssertEqual(LineOps.transformCase("hello_world", mode: .camel),
                       "helloWorld")
    }

    func test_case_camel_handlesMixedSeparators() {
        XCTAssertEqual(LineOps.transformCase("foo-bar baz", mode: .camel),
                       "fooBarBaz")
    }

    func test_case_snake() {
        XCTAssertEqual(LineOps.transformCase("Hello World", mode: .snake),
                       "hello_world")
    }

    func test_case_snake_fromCamel() {
        XCTAssertEqual(LineOps.transformCase("helloWorld", mode: .snake),
                       "hello_world")
    }

    func test_case_kebab() {
        XCTAssertEqual(LineOps.transformCase("Hello World", mode: .kebab),
                       "hello-world")
    }

    func test_case_kebab_fromCamel() {
        XCTAssertEqual(LineOps.transformCase("HelloWorld", mode: .kebab),
                       "hello-world")
    }
}
