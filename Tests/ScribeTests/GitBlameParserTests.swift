//
//  GitBlameParserTests.swift
//  Phase 35c-i — pure-function tests for the `git blame --porcelain`
//  parser. The parser is the only blame-related surface that doesn't
//  need /usr/bin/git, so we lock its decoding contract independently
//  of the integration tests in GitClientWriteIntegrationTests.
//
//  We pin:
//    1. Single-commit blame round-trip (header + metadata + body).
//    2. SHA-cache reuse across subsequent groups.
//    3. Multi-commit interleaving — metadata order survives.
//    4. The "all-zeros" sentinel SHA → isUncommitted == true.
//    5. SHA-256 (64-char) headers parse alongside SHA-1 (40-char).
//    6. Empty / malformed input doesn't crash, returns [].
//

import XCTest
@testable import Scribe

final class GitBlameParserTests: XCTestCase {

    // MARK: - Helpers

    /// 40 hex chars — git's default SHA-1 width. Build by repeating
    /// a single hex character so each test's SHAs stay readable.
    private func sha1(_ ch: Character) -> String {
        String(repeating: String(ch), count: 40)
    }

    private func sha256(_ ch: Character) -> String {
        String(repeating: String(ch), count: 64)
    }

    // MARK: - Single commit, multiple lines

    func test_singleCommit_emitsOneBlamePerSourceLine() {
        // Three source lines from the same commit. The first group
        // carries the metadata block; subsequent groups drop it
        // (porcelain's "first sight" optimisation).
        let sha = sha1("a")
        let raw = """
        \(sha) 1 1 3
        author Foo Bar
        author-mail <foo@bar.com>
        author-time 1700000000
        author-tz +0000
        committer Foo Bar
        committer-mail <foo@bar.com>
        committer-time 1700000000
        committer-tz +0000
        summary first commit
        filename foo.txt
        \thello
        \(sha) 2 2
        \tworld
        \(sha) 3 3
        \tbye
        """
        let lines = GitClient.parseBlamePorcelain(raw)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map(\.lineNo), [1, 2, 3])
        // All three rows should share the same metadata via the
        // sha cache — pin the contract that the second + third
        // group inherit even though their porcelain header is
        // bare.
        for blame in lines {
            XCTAssertEqual(blame.sha, sha)
            XCTAssertEqual(blame.author, "Foo Bar")
            XCTAssertEqual(blame.authorEmail, "<foo@bar.com>")
            XCTAssertEqual(blame.authorTime, 1700000000)
            XCTAssertEqual(blame.summary, "first commit")
            XCTAssertFalse(blame.isUncommitted)
        }
    }

    // MARK: - Multi-commit interleaving

    func test_multiCommit_metadataIsCachedPerSha() {
        // Two commits, alternating lines. The parser has to keep
        // each sha's metadata separately and pick the right cache
        // entry on group-header lookup.
        let alpha = sha1("a")
        let beta  = sha1("b")
        let raw = """
        \(alpha) 1 1
        author Alice
        author-mail <alice@x>
        author-time 1700000000
        summary alpha
        filename f.txt
        \tline-1
        \(beta) 2 2
        author Bob
        author-mail <bob@y>
        author-time 1701000000
        summary beta
        filename f.txt
        \tline-2
        \(alpha) 3 3
        \tline-3
        \(beta) 4 4
        \tline-4
        """
        let lines = GitClient.parseBlamePorcelain(raw)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].author, "Alice")
        XCTAssertEqual(lines[1].author, "Bob")
        // Alice on line 3 (cache hit, no metadata in porcelain).
        XCTAssertEqual(lines[2].author, "Alice")
        XCTAssertEqual(lines[2].sha, alpha)
        // Bob on line 4 (cache hit).
        XCTAssertEqual(lines[3].author, "Bob")
        XCTAssertEqual(lines[3].sha, beta)
    }

    // MARK: - Uncommitted lines

    func test_allZerosSha_marksLineUncommitted() {
        // git emits the all-zeros SHA for working-tree changes
        // that haven't been committed yet — `git blame foo.txt`
        // on a dirty file shows them with author "Not Committed
        // Yet". The struct's isUncommitted helper is what UI
        // code uses to skip those lines on the inline annotation.
        let zero = String(repeating: "0", count: 40)
        let raw = """
        \(zero) 1 1
        author Not Committed Yet
        author-mail <not.committed.yet>
        author-time 1700000000
        summary Version of foo.txt from foo.txt
        filename foo.txt
        \tlocal edit
        """
        let lines = GitClient.parseBlamePorcelain(raw)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].isUncommitted)
        XCTAssertEqual(lines[0].author, "Not Committed Yet")
    }

    // MARK: - SHA-256 support

    func test_sha256Header_parsesSameAsSha1() {
        // `git init --object-format=sha256` produces 64-char
        // hashes; the parser accepts both lengths so we don't
        // have to ship a second build of Scribe for sha256 repos.
        let s = sha256("c")
        let raw = """
        \(s) 1 1
        author Carol
        author-mail <carol@z>
        author-time 1700000001
        summary sha256 commit
        filename f.txt
        \tcontent
        """
        let lines = GitClient.parseBlamePorcelain(raw)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].sha, s)
        XCTAssertEqual(lines[0].author, "Carol")
    }

    // MARK: - Robustness

    func test_emptyInput_returnsEmptyList() {
        XCTAssertTrue(GitClient.parseBlamePorcelain("").isEmpty)
        XCTAssertTrue(GitClient.parseBlamePorcelain("\n\n\n").isEmpty)
    }

    func test_malformedHeader_isSkippedRatherThanCrash() {
        // A line that *looks* sha-shaped but has wrong width or
        // non-hex chars should not be treated as a group header.
        // The parser stays empty rather than throwing.
        let raw = """
        deadbeef 1 1
        zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz 1 1
        author Mallory
        \tnot a real source line because no header opened
        """
        XCTAssertTrue(GitClient.parseBlamePorcelain(raw).isEmpty)
    }

    func test_metadataBeforeHeader_isDropped() {
        // Defensive: stray "author Foo" outside any open group
        // shouldn't leak into the next group's metadata.
        let sha = sha1("d")
        let raw = """
        author Stray
        author-mail <stray@x>
        \(sha) 1 1
        author Real
        author-mail <real@x>
        author-time 1700000002
        summary real
        filename f.txt
        \tcontent
        """
        let lines = GitClient.parseBlamePorcelain(raw)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].author, "Real")
        XCTAssertEqual(lines[0].authorEmail, "<real@x>")
    }

    // MARK: - Final-line numbering

    func test_finalLineNumber_isSecondNumericInHeader() {
        // After a re-line-mapping commit (e.g. cherry-pick that
        // shifts blocks around), `orig` and `final` differ. The
        // parser must use the *final* line number for display.
        let sha = sha1("e")
        let raw = """
        \(sha) 7 42
        author Eve
        author-mail <eve@x>
        author-time 1700000003
        summary moved block
        filename f.txt
        \tcontent
        """
        let lines = GitClient.parseBlamePorcelain(raw)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].lineNo, 42)
    }
}
