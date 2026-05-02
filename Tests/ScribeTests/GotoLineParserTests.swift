//
//  GotoLineParserTests.swift
//  Phase 49c — `:line:col` Quick Open route. Pre-49c the parser
//  silently dropped the column segment; this suite locks in the new
//  behaviour and proves the parsed column round-trips through
//  `gotoLineCommands` into `Document.pendingScroll`.
//

import XCTest
@testable import Scribe

@MainActor
final class GotoLineParserTests: XCTestCase {

    private typealias Parsed = QuickOpenController.ParsedGotoLineQuery

    // MARK: - parseGotoLineQuery — line only

    func test_lineOnly_parsesLineWithNilColumn() {
        XCTAssertEqual(QuickOpenController.parseGotoLineQuery("42"),
                       Parsed(line: 42, column: nil))
    }

    func test_lineOnly_trimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(QuickOpenController.parseGotoLineQuery("  42  "),
                       Parsed(line: 42, column: nil))
    }

    // MARK: - parseGotoLineQuery — line + column

    func test_lineAndColumn_parsesBoth() {
        XCTAssertEqual(QuickOpenController.parseGotoLineQuery("42:7"),
                       Parsed(line: 42, column: 7))
    }

    func test_lineAndColumn_trimsWhitespaceOnEachSegment() {
        XCTAssertEqual(QuickOpenController.parseGotoLineQuery(" 42 : 7 "),
                       Parsed(line: 42, column: 7))
    }

    func test_lineAndColumn_extraSegmentsIgnored() {
        // Excess `:9` should never surface; the editor only models
        // line+column, so anything beyond the second segment is
        // silently dropped rather than rejecting the whole query.
        XCTAssertEqual(QuickOpenController.parseGotoLineQuery("42:7:9"),
                       Parsed(line: 42, column: 7))
    }

    // MARK: - parseGotoLineQuery — column edge cases

    func test_trailingColonWithoutColumn_returnsNilColumn() {
        XCTAssertEqual(QuickOpenController.parseGotoLineQuery("42:"),
                       Parsed(line: 42, column: nil))
    }

    func test_nonNumericColumnIgnored() {
        // Mistyped column shouldn't reject the line jump — being
        // generous here keeps `:42:abc` behaving like the user's
        // actual intent (jump to line 42).
        XCTAssertEqual(QuickOpenController.parseGotoLineQuery("42:abc"),
                       Parsed(line: 42, column: nil))
    }

    func test_zeroColumnIgnored() {
        // Editor numbers from 1; a zero column is meaningless and
        // we drop it instead of clamping silently.
        XCTAssertEqual(QuickOpenController.parseGotoLineQuery("42:0"),
                       Parsed(line: 42, column: nil))
    }

    func test_negativeColumnIgnored() {
        XCTAssertEqual(QuickOpenController.parseGotoLineQuery("42:-3"),
                       Parsed(line: 42, column: nil))
    }

    // MARK: - parseGotoLineQuery — rejects

    func test_emptyStringRejects() {
        XCTAssertNil(QuickOpenController.parseGotoLineQuery(""))
    }

    func test_whitespaceOnlyRejects() {
        XCTAssertNil(QuickOpenController.parseGotoLineQuery("   "))
    }

    func test_nonNumericLineRejects() {
        XCTAssertNil(QuickOpenController.parseGotoLineQuery("abc"))
    }

    func test_zeroLineRejects() {
        XCTAssertNil(QuickOpenController.parseGotoLineQuery("0"))
    }

    func test_negativeLineRejects() {
        XCTAssertNil(QuickOpenController.parseGotoLineQuery("-5"))
    }

    // MARK: - gotoLineCommands integration

    func test_gotoLineCommand_lineOnly_writesLineWithNilColumnIntoPendingScroll() {
        let doc = Document(title: "x.swift")
        let commands = QuickOpenController.gotoLineCommands(stripped: "10", doc: doc)
        XCTAssertEqual(commands.count, 1)

        commands[0].perform()
        XCTAssertEqual(doc.pendingScroll,
                       PendingScrollTarget(line: 10, column: nil))
    }

    func test_gotoLineCommand_withColumn_writesLineAndColumnIntoPendingScroll() {
        let doc = Document(title: "x.swift")
        let commands = QuickOpenController.gotoLineCommands(stripped: "10:5", doc: doc)
        XCTAssertEqual(commands.count, 1)

        commands[0].perform()
        XCTAssertEqual(doc.pendingScroll,
                       PendingScrollTarget(line: 10, column: 5))
    }

    func test_gotoLineCommand_idDifferentiatesByColumn() {
        // Without different ids the palette would treat `:10` and
        // `:10:5` as the same command and risk de-duplicating one.
        let doc = Document(title: "x.swift")
        let lineOnlyId = QuickOpenController.gotoLineCommands(stripped: "10", doc: doc).first?.id
        let withColId  = QuickOpenController.gotoLineCommands(stripped: "10:5", doc: doc).first?.id

        XCTAssertNotNil(lineOnlyId)
        XCTAssertNotNil(withColId)
        XCTAssertNotEqual(lineOnlyId, withColId)
        XCTAssertTrue(withColId?.hasSuffix(":10:5") == true,
                      "expected id to encode line+column, got \(withColId ?? "nil")")
    }

    func test_gotoLineCommand_nilDocReturnsEmpty() {
        XCTAssertTrue(QuickOpenController.gotoLineCommands(stripped: "42", doc: nil).isEmpty)
    }

    func test_gotoLineCommand_invalidQueryReturnsEmpty() {
        let doc = Document(title: "x.swift")
        XCTAssertTrue(QuickOpenController.gotoLineCommands(stripped: "abc", doc: doc).isEmpty)
        XCTAssertTrue(QuickOpenController.gotoLineCommands(stripped: "", doc: doc).isEmpty)
    }
}
