//
//  GitBranchParserTests.swift
//  Phase 35b-4-a — pure-function tests for the branch list parser.
//  The parser is the only branch-related surface that doesn't need
//  /usr/bin/git, so we lock its decoding contract independently of
//  the integration tests in GitClientWriteIntegrationTests.
//
//  We pin:
//    1. refs/heads/  vs refs/remotes/  classification.
//    2. The HEAD `*` flag → isCurrent.
//    3. Upstream short-name decoding for local branches.
//    4. Symbolic refs (origin/HEAD → origin/main) are skipped.
//    5. Empty / malformed lines don't crash the parser.
//

import XCTest
@testable import Scribe

final class GitBranchParserTests: XCTestCase {

    // MARK: - Classification

    func test_localAndRemoteBranches_areClassifiedByPrefix() {
        // Realistic for-each-ref dump: one local + one remote-
        // tracking, no symrefs, no upstream wired up.
        let raw = """
        refs/heads/main||\u{007C}\u{007C}\u{007C}
        refs/remotes/origin/main|||
        """
        // Note: empty trailing fields show up as empty strings
        // because we use omittingEmptySubsequences: false. The
        // top line above is just `refs/heads/main|||`; pasted
        // here with explicit `\u{007C}` codepoints to avoid
        // accidental \"smart\" pipe substitution by editors.
        let canonical = """
        refs/heads/main|||
        refs/remotes/origin/main|||
        """
        let branches = GitClient.parseBranches(canonical)
        XCTAssertEqual(branches.count, 2)
        XCTAssertEqual(branches[0],
                       GitClient.Branch(name: "main",
                                        isCurrent: false,
                                        isRemote: false,
                                        upstream: nil))
        XCTAssertEqual(branches[1],
                       GitClient.Branch(name: "origin/main",
                                        isCurrent: false,
                                        isRemote: true,
                                        upstream: nil))
        _ = raw // silence unused-let
    }

    // MARK: - HEAD pointer

    func test_headFlag_marksCurrentBranch() {
        // for-each-ref emits "*" in the %(HEAD) column iff the ref
        // is the current branch; everything else is empty. Pin the
        // "*"-only contract so we don't flip the flag on whitespace.
        let raw = """
        refs/heads/main|*||
        refs/heads/feature|||
        """
        let branches = GitClient.parseBranches(raw)
        XCTAssertEqual(branches.count, 2)
        XCTAssertEqual(branches[0].name, "main")
        XCTAssertTrue(branches[0].isCurrent)
        XCTAssertEqual(branches[1].name, "feature")
        XCTAssertFalse(branches[1].isCurrent)
    }

    // MARK: - Upstream pointer

    func test_upstreamShortName_isDecodedForLocal() {
        // The %(upstream:short) column carries the short name like
        // "origin/main" for a local branch tracking that ref. Empty
        // means no upstream wired up.
        let raw = """
        refs/heads/main|*|origin/main|
        refs/heads/orphan|||
        """
        let branches = GitClient.parseBranches(raw)
        XCTAssertEqual(branches.count, 2)
        XCTAssertEqual(branches[0].upstream, "origin/main")
        XCTAssertNil(branches[1].upstream)
    }

    func test_remoteBranches_haveNoUpstream() {
        // Remote-tracking branches don't themselves track another
        // ref — even if git put something in the column we ignore
        // it. Sanity-check the empty-string path.
        let raw = """
        refs/remotes/origin/main|||
        refs/remotes/origin/feat||garbage|
        """
        let branches = GitClient.parseBranches(raw)
        XCTAssertEqual(branches[0].upstream, nil)
        // Even when garbage shows up, our parser stores it as-is —
        // the decision to ignore upstream for remotes is one the
        // UI makes (it's documented in `Branch.upstream`'s comment
        // that remote refs leave it nil from `branches(repo:)`).
        // Pin the parser-level honesty: it doesn't second-guess
        // git's column.
        XCTAssertEqual(branches[1].upstream, "garbage")
    }

    // MARK: - Symbolic refs

    func test_symbolicRefs_areSkipped() {
        // origin/HEAD is a symbolic alias for origin/main; including
        // it in the picker would be confusing duplication. The
        // %(symref) column is non-empty for symrefs, and that's
        // our skip signal.
        let raw = """
        refs/remotes/origin/HEAD|||refs/remotes/origin/main
        refs/remotes/origin/main|||
        """
        let branches = GitClient.parseBranches(raw)
        XCTAssertEqual(branches.count, 1)
        XCTAssertEqual(branches[0].name, "origin/main")
    }

    // MARK: - Robustness

    func test_emptyInput_returnsEmpty() {
        XCTAssertEqual(GitClient.parseBranches(""), [])
    }

    func test_malformedLines_areDropped() {
        // Two-field line is too short → drop. A line without a
        // recognised prefix → drop. The good line in between still
        // parses, proving the compactMap doesn't bail on the first
        // bad one.
        let raw = """
        refs/heads/good|||
        no-pipes-here
        refs/tags/v1|||
        too|few
        """
        let branches = GitClient.parseBranches(raw)
        XCTAssertEqual(branches.count, 1)
        XCTAssertEqual(branches[0].name, "good")
    }

    // MARK: - Slash in name

    func test_localBranchWithSlash_isPreservedExactly() {
        // Branch names with a slash (e.g. "feat/x") are common —
        // they go under refs/heads/feat/x and the short name is
        // "feat/x". Pin that we don't accidentally trim past the
        // first slash.
        let raw = """
        refs/heads/feat/payments|||
        """
        let branches = GitClient.parseBranches(raw)
        XCTAssertEqual(branches.count, 1)
        XCTAssertEqual(branches[0].name, "feat/payments")
        XCTAssertFalse(branches[0].isRemote)
    }

    func test_remoteBranchWithSlash_keepsRemotePrefix() {
        // "origin/feat/x" → name "origin/feat/x". The picker
        // strips the `<remote>/` prefix only when checking out;
        // the parser itself reports the full short name.
        let raw = """
        refs/remotes/origin/feat/payments|||
        """
        let branches = GitClient.parseBranches(raw)
        XCTAssertEqual(branches.count, 1)
        XCTAssertEqual(branches[0].name, "origin/feat/payments")
        XCTAssertTrue(branches[0].isRemote)
    }
}
