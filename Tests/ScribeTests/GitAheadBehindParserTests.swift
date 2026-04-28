//
//  GitAheadBehindParserTests.swift
//  Phase 35b-2c — pure-function tests for the rev-list output
//  parser. Split out from the integration suite because the
//  parser has no dependency on /usr/bin/git, so these tests run
//  on every runner regardless of git availability.
//
//  Surface under test: `GitClient.parseAheadBehind(_:)`. Counter-
//  intuitively the most error-prone case isn't large numbers, it's
//  the whitespace shape — git emits tab-separated normally but
//  some 1.x versions column-align with multiple spaces, and our
//  parser must accept both.
//

import XCTest
@testable import Scribe

final class GitAheadBehindParserTests: XCTestCase {

    func test_tabSeparated_isParsed() {
        let ab = GitClient.parseAheadBehind("3\t5\n")
        XCTAssertEqual(ab, GitClient.AheadBehind(ahead: 3, behind: 5))
    }

    func test_spaceAlignedFromOlderGit_isParsed() {
        // git 1.x prints `<ahead><spaces><behind>`; whitespace-split
        // makes both shapes equivalent.
        let ab = GitClient.parseAheadBehind("  12   0\n")
        XCTAssertEqual(ab, GitClient.AheadBehind(ahead: 12, behind: 0))
    }

    func test_zeroZero_returnsUpToDate() {
        let ab = GitClient.parseAheadBehind("0\t0\n")
        XCTAssertEqual(ab, GitClient.AheadBehind(ahead: 0, behind: 0))
        XCTAssertTrue(ab?.isUpToDate ?? false)
        XCTAssertFalse(ab?.diverged ?? true)
    }

    func test_diverged_flagsBothAheadAndBehind() {
        let ab = GitClient.parseAheadBehind("4\t6")
        XCTAssertTrue(ab?.diverged ?? false)
        XCTAssertFalse(ab?.isUpToDate ?? true)
    }

    func test_emptyInput_returnsNil() {
        XCTAssertNil(GitClient.parseAheadBehind(""))
        XCTAssertNil(GitClient.parseAheadBehind("\n"))
        XCTAssertNil(GitClient.parseAheadBehind("   \t \n"))
    }

    func test_malformed_returnsNil() {
        // Single number — git will never emit this on success but we
        // should refuse to make up a "behind: 0" rather than guess.
        XCTAssertNil(GitClient.parseAheadBehind("3"))
        // Three columns is also wrong.
        XCTAssertNil(GitClient.parseAheadBehind("1\t2\t3"))
        // Non-numeric.
        XCTAssertNil(GitClient.parseAheadBehind("foo\tbar"))
    }
}
