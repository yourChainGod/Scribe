//
//  MergeConflictParserTests.swift
//  Phase 68 — confirms the parser finds every git conflict block
//  it should, ignores lines that look marker-ish but aren't, and
//  keeps its line-number + utf16-range bookkeeping accurate across
//  LF / CRLF / diff3 / malformed inputs.
//

import XCTest
@testable import Scribe

final class MergeConflictParserTests: XCTestCase {

    // MARK: - Baseline / happy paths

    func test_emptyInput_returnsNoConflicts() {
        XCTAssertTrue(MergeConflictParser.parse("").isEmpty)
    }

    func test_noMarkers_returnsNoConflicts() {
        let src = """
        func hello() {
            return "world"
        }
        """
        XCTAssertTrue(MergeConflictParser.parse(src).isEmpty)
    }

    func test_singleConflict_simple() {
        let src = """
        line above
        <<<<<<< HEAD
        ours line
        =======
        theirs line
        >>>>>>> feature
        line below
        """
        let conflicts = MergeConflictParser.parse(src)
        XCTAssertEqual(conflicts.count, 1)
        let c = conflicts[0]
        XCTAssertEqual(c.startLine, 2)
        XCTAssertEqual(c.endLine, 6)
        XCTAssertEqual(c.currentText, "ours line")
        XCTAssertEqual(c.incomingText, "theirs line")
        XCTAssertNil(c.baseText)
        XCTAssertEqual(c.currentLabel, "HEAD")
        XCTAssertEqual(c.incomingLabel, "feature")
        XCTAssertNil(c.baseLabel)
    }

    func test_twoConflicts_returnsBothInOrder() {
        let src = """
        prefix
        <<<<<<< HEAD
        A
        =======
        B
        >>>>>>> one
        middle
        <<<<<<< HEAD
        C
        =======
        D
        >>>>>>> two
        suffix
        """
        let conflicts = MergeConflictParser.parse(src)
        XCTAssertEqual(conflicts.count, 2)
        XCTAssertEqual(conflicts[0].incomingLabel, "one")
        XCTAssertEqual(conflicts[1].incomingLabel, "two")
        XCTAssertLessThan(conflicts[0].range.location,
                          conflicts[1].range.location)
    }

    // MARK: - diff3

    func test_diff3Conflict_capturesBaseBlock() {
        let src = """
        <<<<<<< HEAD
        ours
        ||||||| ancestor-sha
        shared base
        =======
        theirs
        >>>>>>> feature
        """
        let c = MergeConflictParser.parse(src)[0]
        XCTAssertEqual(c.currentText, "ours")
        XCTAssertEqual(c.baseText, "shared base")
        XCTAssertEqual(c.incomingText, "theirs")
        XCTAssertEqual(c.baseLabel, "ancestor-sha")
    }

    // MARK: - Multi-line bodies

    func test_multiLineBodies_joinedWithLineBreaks() {
        let src = """
        <<<<<<< HEAD
        one
        two
        three
        =======
        A
        B
        >>>>>>> feature
        """
        let c = MergeConflictParser.parse(src)[0]
        XCTAssertEqual(c.currentText, "one\ntwo\nthree")
        XCTAssertEqual(c.incomingText, "A\nB")
    }

    func test_emptySides_treatedAsEmptyStrings() {
        let src = """
        <<<<<<< HEAD
        =======
        >>>>>>> feature
        """
        let c = MergeConflictParser.parse(src)[0]
        XCTAssertEqual(c.currentText, "")
        XCTAssertEqual(c.incomingText, "")
    }

    // MARK: - Labels

    func test_labelsMayBeMissing() {
        let src = """
        <<<<<<<
        ours
        =======
        theirs
        >>>>>>>
        """
        let c = MergeConflictParser.parse(src)[0]
        XCTAssertEqual(c.currentLabel, "")
        XCTAssertEqual(c.incomingLabel, "")
    }

    func test_labelsWithSpaces_trimmedCleanly() {
        let src = """
        <<<<<<<   HEAD has weight   
        ours
        =======
        theirs
        >>>>>>>   feature/branch  
        """
        let c = MergeConflictParser.parse(src)[0]
        XCTAssertEqual(c.currentLabel, "HEAD has weight")
        XCTAssertEqual(c.incomingLabel, "feature/branch")
    }

    // MARK: - Line-ending tolerance

    func test_crlfLineEndings_accepted() {
        let src = "<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\n"
        let conflicts = MergeConflictParser.parse(src)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].currentText, "ours")
        XCTAssertEqual(conflicts[0].incomingText, "theirs")
    }

    // MARK: - False-positive defences

    func test_separatorMustBeExactlySevenEquals() {
        // 8+ equal signs (common in comment banners) must NOT
        // terminate the "ours" section. Since there's no real
        // `=======` line, the block is malformed and dropped.
        let src = """
        <<<<<<< HEAD
        ours
        ========  header
        theirs
        >>>>>>> feature
        """
        XCTAssertTrue(MergeConflictParser.parse(src).isEmpty,
                      "long streak of '=' must not count as a separator")
    }

    func test_indentedMarkers_notRecognised() {
        // Conflict markers are column-0 by definition.
        let src = """
            <<<<<<< HEAD
            ours
            =======
            theirs
            >>>>>>> feature
        """
        XCTAssertTrue(MergeConflictParser.parse(src).isEmpty,
                      "indented markers must not be recognised")
    }

    func test_unterminatedConflict_isDropped() {
        // Missing `>>>>>>>` — no block should be emitted.
        let src = """
        <<<<<<< HEAD
        ours
        =======
        theirs
        """
        XCTAssertTrue(MergeConflictParser.parse(src).isEmpty)
    }

    func test_markerOutOfOrder_isDropped() {
        // `>>>>>>>` before `=======` — parser resets.
        let src = """
        <<<<<<< HEAD
        ours
        >>>>>>> feature
        =======
        theirs
        """
        XCTAssertTrue(MergeConflictParser.parse(src).isEmpty)
    }

    func test_nestedOpeningMarker_restartsBlock() {
        // A second `<<<<<<<` abandons the first (malformed) block
        // and starts fresh. Only the second, well-formed block is
        // emitted.
        let src = """
        <<<<<<< HEAD-A
        partially written
        <<<<<<< HEAD-B
        ours
        =======
        theirs
        >>>>>>> feature
        """
        let conflicts = MergeConflictParser.parse(src)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].currentLabel, "HEAD-B")
    }

    // MARK: - Range / line-number bookkeeping

    func test_rangeCoversMarkerLines_andTrailingNewline() {
        let src = "prefix\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\ntail"
        let c = MergeConflictParser.parse(src)[0]
        let nsString = src as NSString
        let sliced = nsString.substring(with: c.range)
        XCTAssertTrue(sliced.hasPrefix("<<<<<<<"),
                      "range must start at the opening marker")
        XCTAssertTrue(sliced.contains(">>>>>>>"),
                      "range must include the closing marker")
        XCTAssertTrue(sliced.hasSuffix("\n"),
                      "range must include the newline after the closing marker")
    }

    func test_rangeOmitsTrailingNewline_whenConflictIsEOF() {
        // Closing `>>>>>>>` is the very last line with no trailing
        // newline. Range length must equal length of the last line
        // plus the bytes before it.
        let src = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature"
        let c = MergeConflictParser.parse(src)[0]
        XCTAssertEqual(c.range.location, 0)
        XCTAssertEqual(c.range.length, (src as NSString).length)
    }
}
