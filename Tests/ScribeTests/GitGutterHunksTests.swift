//
//  GitGutterHunksTests.swift
//  Phase 31b — locks down the grouping + next/prev wrap behaviour
//  the ⌥⇧↑/↓ commands depend on. Empty / single-line / contiguous
//  / sparse / wrap edges all matter.
//

import XCTest
@testable import Scribe

final class GitGutterHunksTests: XCTestCase {

    // MARK: - groups()

    func testEmptyMapHasNoGroups() {
        XCTAssertEqual(GitGutterHunks.groups(in: [:]), [])
    }

    func testSingleLineYieldsOneSingletonGroup() {
        XCTAssertEqual(GitGutterHunks.groups(in: [42: .added]),
                       [42...42])
    }

    func testContiguousLinesCollapseIntoOneRange() {
        let map: [Int: GitGutterStatus] = [
            10: .added, 11: .added, 12: .modified
        ]
        XCTAssertEqual(GitGutterHunks.groups(in: map), [10...12])
    }

    func testGapEvenOfSizeOneSplitsRanges() {
        // Lines 5 and 7 are not adjacent (line 6 is unchanged), so
        // they belong to different hunks.
        let map: [Int: GitGutterStatus] = [
            5: .added, 7: .modified
        ]
        XCTAssertEqual(GitGutterHunks.groups(in: map), [5...5, 7...7])
    }

    func testMixedShapeGroupsByContiguity() {
        // Three hunks: 2–4, 7, 9–10.
        let map: [Int: GitGutterStatus] = [
            2: .added, 3: .modified, 4: .added,
            7: .deletedAbove,
            9: .modified, 10: .modified
        ]
        XCTAssertEqual(GitGutterHunks.groups(in: map),
                       [2...4, 7...7, 9...10])
    }

    func testGroupsAreSortedAscending() {
        // Insertion order in a dictionary is non-deterministic; the
        // contract is that `groups()` always returns ranges sorted
        // by lowerBound.
        let map: [Int: GitGutterStatus] = [
            20: .added, 5: .modified, 12: .added
        ]
        let g = GitGutterHunks.groups(in: map)
        XCTAssertEqual(g, [5...5, 12...12, 20...20])
    }

    // MARK: - next()

    func testNextOnEmptyMapReturnsNil() {
        XCTAssertNil(GitGutterHunks.next(after: 1, in: [:]))
    }

    func testNextSkipsHunkContainingCurrentLine() {
        // Cursor is inside hunk 2…4. "Next" must skip past it and
        // land on the start of the *following* hunk (line 7).
        let map: [Int: GitGutterStatus] = [
            2: .added, 3: .added, 4: .added,
            7: .modified
        ]
        XCTAssertEqual(GitGutterHunks.next(after: 3, in: map), 7)
    }

    func testNextFromBeforeFirstHunkReturnsFirstHunk() {
        let map: [Int: GitGutterStatus] = [
            10: .added, 20: .modified
        ]
        XCTAssertEqual(GitGutterHunks.next(after: 1, in: map), 10)
    }

    func testNextWrapsToFirstHunkWhenPastLast() {
        // Cursor on line 99 is after every hunk; "Next" wraps to
        // the top of the file (line 5).
        let map: [Int: GitGutterStatus] = [
            5: .added, 12: .modified
        ]
        XCTAssertEqual(GitGutterHunks.next(after: 99, in: map), 5)
    }

    // MARK: - previous()

    func testPreviousOnEmptyMapReturnsNil() {
        XCTAssertNil(GitGutterHunks.previous(before: 1, in: [:]))
    }

    func testPreviousSkipsHunkContainingCurrentLine() {
        // Cursor inside hunk 7. "Previous" must land on the start
        // of the hunk before it (line 2).
        let map: [Int: GitGutterStatus] = [
            2: .added,
            7: .modified, 8: .modified
        ]
        XCTAssertEqual(GitGutterHunks.previous(before: 8, in: map), 2)
    }

    func testPreviousFromAfterLastHunkReturnsLastHunkStart() {
        let map: [Int: GitGutterStatus] = [
            10: .added, 20: .modified, 21: .modified
        ]
        XCTAssertEqual(GitGutterHunks.previous(before: 99, in: map), 20)
    }

    func testPreviousWrapsToLastHunkWhenBeforeFirst() {
        // Cursor on line 1 is before every hunk; "Previous" wraps
        // to the last hunk (start = 30).
        let map: [Int: GitGutterStatus] = [
            10: .added,
            30: .modified, 31: .modified
        ]
        XCTAssertEqual(GitGutterHunks.previous(before: 1, in: map), 30)
    }
}
