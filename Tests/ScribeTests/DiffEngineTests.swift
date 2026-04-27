//
//  DiffEngineTests.swift
//  Phase 5 — verify the Myers implementation against hand-rolled
//  expected ops + the round-trip property "ops cover both inputs".
//

import XCTest
@testable import Scribe

final class DiffEngineTests: XCTestCase {

    // MARK: - splitLines

    func test_splitLines_handlesAllLineEndings() {
        XCTAssertEqual(DiffEngine.splitLines(""), [])
        XCTAssertEqual(DiffEngine.splitLines("a"), ["a"])
        XCTAssertEqual(DiffEngine.splitLines("a\nb"), ["a", "b"])
        XCTAssertEqual(DiffEngine.splitLines("a\r\nb"), ["a", "b"])
        XCTAssertEqual(DiffEngine.splitLines("a\rb"), ["a", "b"])
        // Trailing newline → empty slot, mirrors Scintilla.
        XCTAssertEqual(DiffEngine.splitLines("a\n"), ["a", ""])
    }

    // MARK: - identical input

    func test_identicalInputs_areOneEqualOp() {
        let r = DiffEngine.compare("a\nb\nc", "a\nb\nc")
        XCTAssertEqual(r.ops.count, 1)
        XCTAssertEqual(r.ops.first?.kind, .equal)
        XCTAssertEqual(r.ops.first?.leftRange, 0..<3)
        XCTAssertEqual(r.ops.first?.rightRange, 0..<3)
    }

    // MARK: - pure insertion

    func test_pureInsertion() {
        let r = DiffEngine.compare("a\nc", "a\nb\nc")
        let kinds = r.ops.map(\.kind)
        XCTAssertEqual(kinds, [.equal, .insert, .equal])
        XCTAssertEqual(r.ops[1].rightRange, 1..<2)
        XCTAssertTrue(r.ops[1].leftRange.isEmpty)
    }

    // MARK: - pure deletion

    func test_pureDeletion() {
        let r = DiffEngine.compare("a\nb\nc", "a\nc")
        let kinds = r.ops.map(\.kind)
        XCTAssertEqual(kinds, [.equal, .delete, .equal])
        XCTAssertEqual(r.ops[1].leftRange, 1..<2)
        XCTAssertTrue(r.ops[1].rightRange.isEmpty)
    }

    // MARK: - replacement coalesces

    func test_deleteAndInsertCoalesceIntoReplace() {
        let r = DiffEngine.compare("a\nB\nc", "a\nbb\nc")
        let kinds = r.ops.map(\.kind)
        XCTAssertEqual(kinds, [.equal, .replace, .equal])
        XCTAssertEqual(r.ops[1].leftRange, 1..<2)
        XCTAssertEqual(r.ops[1].rightRange, 1..<2)
    }

    // MARK: - empty / one-side-empty

    func test_oneSideEmpty() {
        let l = DiffEngine.compare("", "a\nb")
        XCTAssertEqual(l.ops.map(\.kind), [.insert])
        XCTAssertEqual(l.ops[0].rightRange, 0..<2)

        let r = DiffEngine.compare("a\nb", "")
        XCTAssertEqual(r.ops.map(\.kind), [.delete])
        XCTAssertEqual(r.ops[0].leftRange, 0..<2)
    }

    // MARK: - coverage property

    func test_opsCoverBothInputsExactly() {
        let cases: [(String, String)] = [
            ("a\nb\nc\nd",       "a\nx\nc\nd"),
            ("alpha\nbeta\ngamma\ndelta", "alpha\nGAMMA\ndelta\nepsilon"),
            ("one",              "two"),
            ("",                 "first\nsecond"),
            ("only-left",        "")
        ]
        for (l, r) in cases {
            let result = DiffEngine.compare(l, r)
            assertCoverage(result)
        }
    }

    private func assertCoverage(_ r: DiffResult,
                                file: StaticString = #file,
                                line: UInt = #line) {
        var leftCursor = 0
        var rightCursor = 0
        for op in r.ops {
            XCTAssertEqual(op.leftRange.lowerBound, leftCursor, file: file, line: line)
            XCTAssertEqual(op.rightRange.lowerBound, rightCursor, file: file, line: line)
            leftCursor = op.leftRange.upperBound
            rightCursor = op.rightRange.upperBound
        }
        XCTAssertEqual(leftCursor, r.leftLines.count, file: file, line: line)
        XCTAssertEqual(rightCursor, r.rightLines.count, file: file, line: line)
    }

    // MARK: - stats

    func test_statsCountAddedRemovedChanged() {
        let r = DiffEngine.compare(
            "alpha\nbeta\ngamma\ndelta",
            "alpha\nGAMMA\ndelta\nepsilon"
        )
        let s = r.stats
        // beta deleted (1) + GAMMA replaces nothing extra,
        // epsilon added (1), gamma → GAMMA is a replace (counts toward changed).
        XCTAssertGreaterThanOrEqual(s.added, 1)
        XCTAssertGreaterThanOrEqual(s.removed + s.changed, 1)
    }
}
