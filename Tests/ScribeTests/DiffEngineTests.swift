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

    // MARK: - Line mapping (Phase 5b synchronised scrolling)

    func test_mapLeftToRight_passesThroughEqualOffsets() {
        let r = DiffEngine.compare("a\nb\nc\nd", "a\nx\nc\nd")
        // ops: equal(0..1), replace(1..2, 1..2), equal(2..4, 2..4)
        XCTAssertEqual(r.mapLeftToRight(0), 0)        // equal head
        XCTAssertEqual(r.mapLeftToRight(2), 2)        // equal tail, exact offset
        XCTAssertEqual(r.mapLeftToRight(3), 3)
    }

    func test_mapLeftToRight_anchorsToHunkStartInsideChanges() {
        let r = DiffEngine.compare("a\nb\nc", "a\nbb\nc")
        // ops: equal(0..1), replace(1..2, 1..2), equal(2..3, 2..3)
        // line 1 is inside the replace; should map to right-side start = 1
        XCTAssertEqual(r.mapLeftToRight(1), 1)
    }

    func test_mapRightToLeft_handlesPureInsertions() {
        let r = DiffEngine.compare("a\nc", "a\nb\nc")
        // ops: equal(0..1, 0..1), insert(0..0, 1..2), equal(1..2, 2..3)
        // Right line 1 is in the insert; left has no corresponding line, so
        // we anchor to the left start of the op (= 1).
        XCTAssertEqual(r.mapRightToLeft(1), 1)
        XCTAssertEqual(r.mapRightToLeft(2), 1)        // equal tail at left=1
    }

    func test_mapClampsToFileEnd() {
        let r = DiffEngine.compare("a\nb", "a\nb\nc\nd")
        XCTAssertEqual(r.mapLeftToRight(99), r.rightLines.count)
        XCTAssertEqual(r.mapRightToLeft(99), r.leftLines.count)
    }

    // MARK: - Word-level diff (Phase 5b-2)

    func test_wordDiff_emptyForEqualText() {
        let wd = DiffEngine.wordDiff(left: "hello world", right: "hello world")
        XCTAssertTrue(wd.leftAddedRanges.isEmpty)
        XCTAssertTrue(wd.rightAddedRanges.isEmpty)
    }

    func test_wordDiff_isolatesChangedToken() {
        // "hello world" vs "hello brave world" — single insertion of
        // "brave" + a separating space. Equality on either side of the
        // change should remain untouched.
        let wd = DiffEngine.wordDiff(left: "hello world",
                                     right: "hello brave world")
        XCTAssertTrue(wd.leftAddedRanges.isEmpty)
        XCTAssertEqual(wd.rightAddedRanges.count, 1)
        let r = wd.rightAddedRanges[0]
        let added = String(("hello brave world" as NSString)
                            .substring(with: NSRange(location: r.lowerBound,
                                                     length: r.upperBound - r.lowerBound)))
        XCTAssertTrue(added.contains("brave"))
    }

    func test_wordDiff_replacementAffectsBothSides() {
        let wd = DiffEngine.wordDiff(left: "let x = 1",
                                     right: "let x = 2")
        XCTAssertEqual(wd.leftAddedRanges.count, 1)
        XCTAssertEqual(wd.rightAddedRanges.count, 1)
        // The change is the single digit '1' / '2'.
        XCTAssertEqual(wd.leftAddedRanges[0].count, 1)
        XCTAssertEqual(wd.rightAddedRanges[0].count, 1)
    }

    func test_wordDiff_keepsPunctuationAsItsOwnToken() {
        // Removing a trailing semicolon should highlight ONLY the ';'.
        let wd = DiffEngine.wordDiff(left: "return;", right: "return")
        XCTAssertEqual(wd.leftAddedRanges.count, 1)
        XCTAssertEqual(wd.leftAddedRanges[0], 6..<7) // index of ';'
        XCTAssertTrue(wd.rightAddedRanges.isEmpty)
    }

    func test_wordDiff_forReplaceOpOnDiffResult() {
        let r = DiffEngine.compare("alpha\nlet x = 1;\nbeta",
                                   "alpha\nlet x = 2;\nbeta")
        let replaceOp = r.ops.first { $0.kind == .replace }
        XCTAssertNotNil(replaceOp)
        let wd = r.wordDiff(for: replaceOp!)
        XCTAssertNotNil(wd)
        XCTAssertEqual(wd!.leftAddedRanges.count, 1)
        XCTAssertEqual(wd!.rightAddedRanges.count, 1)
    }

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

    // MARK: - Memory guard (Phase 74 — OOM 防护)

    /// With a tiny trace budget the guard trips on the very first snapshot
    /// and degrades to a single coarse replace covering both sides in full,
    /// instead of building the O((n+m)²) backtrack trace that would OOM the
    /// process on a large, highly-divergent pair.
    func test_diff_traceBudgetExceeded_degradesToCoarseReplace() {
        let left  = (0..<200).map { "left \($0)" }
        let right = (0..<200).map { "right \($0)" }
        let ops = DiffEngine.diff(left: left, right: right, maxTraceInts: 1)
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].kind, .replace)
        XCTAssertEqual(ops[0].leftRange, 0..<200)
        XCTAssertEqual(ops[0].rightRange, 0..<200)
    }

    /// One-sided inputs degrade to a pure delete / insert (not a replace),
    /// so the coarse fallback still distinguishes the two shapes.
    func test_diff_traceBudgetExceeded_oneSidedDegradesToDeleteOrInsert() {
        let onlyLeft = DiffEngine.diff(left: ["a", "b", "c"], right: [],
                                       maxTraceInts: 1)
        XCTAssertEqual(onlyLeft.map(\.kind), [.delete])
        XCTAssertEqual(onlyLeft[0].leftRange, 0..<3)

        let onlyRight = DiffEngine.diff(left: [], right: ["x", "y"],
                                        maxTraceInts: 1)
        XCTAssertEqual(onlyRight.map(\.kind), [.insert])
        XCTAssertEqual(onlyRight[0].rightRange, 0..<2)
    }

    /// The default budget is large enough that ordinary diffs are never
    /// degraded — identical exact result to the un-guarded algorithm.
    func test_diff_defaultBudget_leavesNormalDiffExact() {
        let ops = DiffEngine.diff(left: ["a", "B", "c"], right: ["a", "bb", "c"])
        XCTAssertEqual(ops.map(\.kind), [.equal, .replace, .equal])
        let r = DiffEngine.compare("a\nB\nc", "a\nbb\nc")
        assertCoverage(r)
    }

    /// The degraded coarse replace is still structurally valid: its ranges
    /// tile both inputs without gaps, so DiffResult consumers (scroll-map,
    /// stats, word-diff) don't trip on it.
    func test_diff_degradedReplace_isStructurallyValid() {
        let left  = (0..<50).map { "L\($0)" }
        let right = (0..<70).map { "R\($0)" }
        let ops = DiffEngine.diff(left: left, right: right, maxTraceInts: 1)
        let r = DiffResult(leftLines: left, rightLines: right, ops: ops)
        assertCoverage(r)
    }
}
