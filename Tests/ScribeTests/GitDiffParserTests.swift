//
//  GitDiffParserTests.swift
//  Phase 31 — verifies the unified-diff parser maps every hunk
//  shape into the right per-line gutter status. Locks in the
//  four canonical cases (add / modify / delete / mixed) plus
//  the edge cases the parser is documented to tolerate.
//

import XCTest
@testable import Scribe

final class GitDiffParserTests: XCTestCase {

    // MARK: - Empty / no-op

    func testEmptyDiffYieldsEmptyMap() {
        XCTAssertEqual(GitDiffParser.parse(""), [:])
    }

    func testHeaderOnlyDiffYieldsEmptyMap() {
        // The `diff --git` and `--- a/…  +++ b/…` preamble lines
        // never start with `@@ ` and must be ignored.
        let diff = """
        diff --git a/foo.txt b/foo.txt
        index abcdef0..1234567 100644
        --- a/foo.txt
        +++ b/foo.txt
        """
        XCTAssertEqual(GitDiffParser.parse(diff), [:])
    }

    // MARK: - Pure addition

    func testPureAdditionMarksEveryNewLine() {
        // 3 brand-new lines starting at line 7.
        let diff = """
        @@ -6,0 +7,3 @@
        +alpha
        +beta
        +gamma
        """
        XCTAssertEqual(GitDiffParser.parse(diff),
                       [7: .added, 8: .added, 9: .added])
    }

    func testSingleLineAdditionDefaultsToLengthOne() {
        // No `,len` after the start ⇒ length 1 by spec.
        let diff = """
        @@ -10,0 +11 @@
        +just one
        """
        XCTAssertEqual(GitDiffParser.parse(diff), [11: .added])
    }

    // MARK: - Pure deletion

    func testPureDeletionMarksLineAfter() {
        // 2 HEAD lines deleted just after working-tree line 4.
        // newStart=4, newLen=0 ⇒ marker at row 4.
        let diff = """
        @@ -5,2 +4,0 @@
        -dropped
        -also-dropped
        """
        XCTAssertEqual(GitDiffParser.parse(diff),
                       [4: .deletedAbove])
    }

    func testDeletionAtFileStartMarksLineOne() {
        // Special case: deleting from the very top gives
        // newStart=0, which the parser remaps to row 1.
        let diff = """
        @@ -1,3 +0,0 @@
        -gone
        -gone
        -gone
        """
        XCTAssertEqual(GitDiffParser.parse(diff),
                       [1: .deletedAbove])
    }

    // MARK: - Replacement

    func testReplacementMarksNewSideAsModified() {
        // 2 HEAD lines replaced by 3 working-tree lines starting at 12.
        let diff = """
        @@ -11,2 +12,3 @@
        -old
        -older
        +new
        +newer
        +newest
        """
        XCTAssertEqual(GitDiffParser.parse(diff),
                       [12: .modified, 13: .modified, 14: .modified])
    }

    // MARK: - Multiple hunks

    func testMultipleHunksMerge() {
        // One file, three independent hunks: add, modify, delete.
        let diff = """
        @@ -0,0 +1,2 @@
        +brand-new
        +brand-new
        @@ -10,1 +12,1 @@
        -was
        +is
        @@ -30,2 +30,0 @@
        -gone
        -gone
        """
        let map = GitDiffParser.parse(diff)
        XCTAssertEqual(map[1],  .added)
        XCTAssertEqual(map[2],  .added)
        XCTAssertEqual(map[12], .modified)
        XCTAssertEqual(map[30], .deletedAbove)
        XCTAssertEqual(map.count, 4)
    }

    // MARK: - Robustness

    func testMalformedHeaderIgnored() {
        // Missing `+` half — parser should drop the malformed
        // hunk silently rather than crash.
        let diff = """
        @@ -1,2 garbage @@
        +x
        """
        XCTAssertEqual(GitDiffParser.parse(diff), [:])
    }

    func testHunkHeadingSuffixIgnored() {
        // Real git diffs sometimes append the enclosing function
        // name after the closing `@@`. The parser must look only
        // at the coordinates, ignoring everything after.
        let diff = """
        @@ -1,1 +1,1 @@ func body()
        -was
        +is
        """
        XCTAssertEqual(GitDiffParser.parse(diff), [1: .modified])
    }

    func testStrongerStatusWinsOverDeletion() {
        // Adjacent hunks — added at row 5 first, then a deletion
        // pointing at row 5. The added status is stronger and must
        // not be downgraded to deletedAbove.
        let diff = """
        @@ -4,0 +5,1 @@
        +added
        @@ -10,1 +5,0 @@
        -dropped
        """
        XCTAssertEqual(GitDiffParser.parse(diff), [5: .added])
    }
}
