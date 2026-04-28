//
//  GitHunkParserTests.swift
//  Phase 35b-3-i — pure-function tests for the hunk parser and the
//  minimal-patch builder. Both surfaces are pure so these tests
//  run on every runner regardless of /usr/bin/git availability;
//  the integration round-trip (parse real `git diff` → apply
//  back via `git apply --cached`) lives in
//  GitClientWriteIntegrationTests where the scratch-repo helpers
//  are.
//
//  What we lock in here:
//    1. Header decoding (coords + section heading).
//    2. Body-line collection (' ' / '+' / '-' / '\\ No newline').
//    3. Multi-hunk streams (boundary detection).
//    4. File-preamble noise (`diff --git`, `--- a/`, `+++ b/`)
//       is skipped before the first `@@`.
//    5. Round-trip rebuild: a parsed hunk should re-emit a patch
//       textually equal to the slice it came from (within the
//       single-hunk subset; we don't try to recover the file
//       preamble).
//

import XCTest
@testable import Scribe

final class GitHunkParserTests: XCTestCase {

    // MARK: - Header

    func test_singleHunk_headerCoordsAndBody() {
        let diff = """
        @@ -10,3 +10,4 @@
         keep
        +inserted
         keep
         keep
        """
        let hunks = GitClient.parseHunks(diff)
        XCTAssertEqual(hunks.count, 1)
        let h = hunks[0]
        XCTAssertEqual(h.oldStart, 10)
        XCTAssertEqual(h.oldLen, 3)
        XCTAssertEqual(h.newStart, 10)
        XCTAssertEqual(h.newLen, 4)
        XCTAssertNil(h.section)
        XCTAssertEqual(h.bodyLines, [
            " keep", "+inserted", " keep", " keep",
        ])
    }

    func test_sectionHeading_isPreserved() {
        // git emits the enclosing function/symbol after the closing
        // `@@`. Preserving it byte-for-byte means a rebuilt minimal
        // patch reads the same as the original slice.
        let diff = """
        @@ -1,1 +1,1 @@ func body()
        -was
        +is
        """
        let hunks = GitClient.parseHunks(diff)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].section, "func body()")
    }

    func test_filePreamble_isSkippedBeforeFirstHunk() {
        // The file-level header (`diff --git` / `index abc..def` /
        // `--- a/` / `+++ b/`) lives outside any `@@`; our parser
        // ignores everything until the first hunk header.
        let diff = """
        diff --git a/foo.txt b/foo.txt
        index abc1234..def5678 100644
        --- a/foo.txt
        +++ b/foo.txt
        @@ -1,1 +1,1 @@
        -was
        +is
        """
        let hunks = GitClient.parseHunks(diff)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].bodyLines, ["-was", "+is"])
    }

    // MARK: - Multiple hunks

    func test_multipleHunks_areSeparatedByHeaders() {
        let diff = """
        @@ -1,2 +1,3 @@
         keep
        +ins
         keep
        @@ -10,1 +11,1 @@ func two()
        -was
        +is
        """
        let hunks = GitClient.parseHunks(diff)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].newStart, 1)
        XCTAssertEqual(hunks[0].bodyLines, [" keep", "+ins", " keep"])
        XCTAssertEqual(hunks[1].section, "func two()")
        XCTAssertEqual(hunks[1].bodyLines, ["-was", "+is"])
    }

    // MARK: - "\ No newline at end of file"

    func test_noNewlineAtEndOfFileSentinel_isCollected() {
        // The "\ No newline at end of file" line technically
        // belongs to the preceding +/- line. `git apply` needs it
        // verbatim — without it, git refuses to apply patches that
        // round-trip a missing-final-newline state.
        let diff = """
        @@ -1,1 +1,1 @@
        -old
        \\ No newline at end of file
        +new
        """
        let hunks = GitClient.parseHunks(diff)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].bodyLines, [
            "-old",
            "\\ No newline at end of file",
            "+new",
        ])
    }

    // MARK: - Empty / malformed

    func test_emptyDiff_returnsEmptyArray() {
        XCTAssertEqual(GitClient.parseHunks(""), [])
    }

    func test_headerOnlyDiff_returnsEmptyArray() {
        // No `@@` ever appears ⇒ no hunks ⇒ empty array. The
        // file-preamble lines are dropped because they're outside
        // a hunk.
        let diff = """
        diff --git a/foo.txt b/foo.txt
        --- a/foo.txt
        +++ b/foo.txt
        """
        XCTAssertEqual(GitClient.parseHunks(diff), [])
    }

    func test_malformedHeader_isSkippedNotCrashing() {
        // Missing `+` half — header is malformed; parser should
        // drop it and continue (current is left nil so subsequent
        // body lines are also ignored).
        let diff = """
        @@ -1,2 garbage @@
        +x
        @@ -10,1 +11,1 @@
        -y
        +z
        """
        let hunks = GitClient.parseHunks(diff)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].newStart, 11)
    }

    // MARK: - Minimal patch builder

    func test_minimalPatch_singleHunk_isApplyShape() {
        // Build a patch from a parsed hunk, verify it has the
        // exact 4-element shape `git apply` accepts (--- / +++
        // pair, header, body lines, trailing newline).
        let diff = """
        @@ -3,3 +3,4 @@ ctx
         a
         b
        +inserted
         c
        """
        let hunk = GitClient.parseHunks(diff)[0]
        let patch = hunk.minimalPatch(forFilePath: "foo.txt")
        XCTAssertEqual(patch, """
        --- a/foo.txt
        +++ b/foo.txt
        @@ -3,3 +3,4 @@ ctx
         a
         b
        +inserted
         c

        """)
    }

    func test_minimalPatch_pinsExplicitLengthFormEvenForLengthOne() {
        // git accepts both `+5` and `+5,1` but the rebuilder always
        // emits `,1` so the round-trip is deterministic. Pin that
        // contract so a future "use shorter form" optimisation
        // doesn't silently break a patch that downstream tooling
        // is parsing strictly.
        let diff = """
        @@ -5 +5 @@
        -was
        +is
        """
        let hunk = GitClient.parseHunks(diff)[0]
        let patch = hunk.minimalPatch(forFilePath: "x")
        XCTAssertTrue(patch.contains("@@ -5,1 +5,1 @@"),
                      "patch should pin explicit ,1 form: \(patch)")
    }

    func test_minimalPatch_preservesNoNewlineSentinel() {
        let diff = """
        @@ -1,1 +1,1 @@
        -old
        \\ No newline at end of file
        +new
        """
        let hunk = GitClient.parseHunks(diff)[0]
        let patch = hunk.minimalPatch(forFilePath: "f")
        XCTAssertTrue(patch.contains("\\ No newline at end of file"),
                      "rebuild dropped the no-newline sentinel: \(patch)")
    }
}
