//
//  GitClientWriteIntegrationTests.swift
//  Phase 35b-2a — verify the three write entry-points (stage /
//  unstage / discardWorkingTree) actually round-trip through real
//  git on disk. Each test creates a throwaway repo under
//  NSTemporaryDirectory and exercises the write path against it,
//  then re-reads `git status` to confirm the staged/unstaged
//  columns moved as expected.
//
//  Why integration here instead of just unit-testing the parser:
//    The parser already has 16 cases covering every porcelain
//    shape we care about; what these tests are pinning is the
//    contract between our argv list (`["add", "--", path]` etc.)
//    and what git actually does to the index. A typo in argv
//    would happily round-trip through the parser and only show up
//    when a user clicks the button — these tests catch that on
//    every CI run.
//
//  Skip behaviour:
//    If `/usr/bin/git` isn't on the runner (defensive — every
//    macOS image we ship to has it), each test bails early so the
//    suite stays green on minimal runners.
//

import XCTest
@testable import Scribe

@MainActor
final class GitClientWriteIntegrationTests: XCTestCase {

    private var repoURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available on this runner"
        )
        // Each test gets its own scratch repo so parallel runs
        // don't race on the same directory. UUID suffix gives us
        // collision-free names without locking ceremony.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-git-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp,
                                                withIntermediateDirectories: true)
        repoURL = tmp
        // `git init` + identity + an initial commit so HEAD exists.
        // Without HEAD `git restore --staged` would fail with a
        // "needs a HEAD" error and our test would surface a false
        // positive failure instead of a real one.
        try runGit(["init", "--quiet"])
        try runGit(["config", "user.email", "test@scribe.app"])
        try runGit(["config", "user.name", "Scribe Test"])
        try seedFile(name: "README.md", contents: "initial\n")
        try runGit(["add", "README.md"])
        try runGit(["commit", "-m", "initial", "--quiet"])
    }

    override func tearDown() async throws {
        if let repoURL {
            try? FileManager.default.removeItem(at: repoURL)
        }
        repoURL = nil
        try await super.tearDown()
    }

    // MARK: - stage

    func test_stage_movesUnstagedModifiedIntoStaged() async throws {
        // Edit README so it shows up as " M" (modified, unstaged).
        try seedFile(name: "README.md", contents: "edited\n")
        var rows = try fetchStatus()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].staged, .unmodified)
        XCTAssertEqual(rows[0].unstaged, .modified)

        // Stage and verify the columns flipped to "M ".
        let result = GitClient.stage(path: "README.md", repo: repoURL)
        guard case .ok = result else {
            XCTFail("stage failed: \(result)")
            return
        }
        rows = try fetchStatus()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].staged, .modified)
        XCTAssertEqual(rows[0].unstaged, .unmodified)
    }

    func test_stage_addsUntrackedAsAdded() async throws {
        // A brand-new file should report "??" first, then "A " after stage.
        try seedFile(name: "newfile.txt", contents: "hello\n")
        var rows = try fetchStatus()
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isUntracked)

        let result = GitClient.stage(path: "newfile.txt", repo: repoURL)
        guard case .ok = result else { XCTFail("\(result)"); return }
        rows = try fetchStatus()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].staged, .added)
    }

    // MARK: - unstage

    func test_unstage_returnsToWorkingTreeOnly() async throws {
        // Set up: edit + stage so we're at "M " before unstaging.
        try seedFile(name: "README.md", contents: "edited\n")
        XCTAssertEqual(GitClient.stage(path: "README.md", repo: repoURL),
                       .ok)
        var rows = try fetchStatus()
        XCTAssertEqual(rows[0].staged, .modified)

        // Unstage; expect status to drop back to " M".
        let result = GitClient.unstage(path: "README.md", repo: repoURL)
        guard case .ok = result else { XCTFail("\(result)"); return }
        rows = try fetchStatus()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].staged, .unmodified)
        XCTAssertEqual(rows[0].unstaged, .modified)
    }

    // MARK: - discard

    func test_discardWorkingTree_restoresFromIndex() async throws {
        // Edit a tracked file, then discard. The on-disk content
        // should match the committed version again, and `git
        // status` should be empty.
        try seedFile(name: "README.md", contents: "edited\n")
        XCTAssertEqual(try fetchStatus().count, 1)

        let result = GitClient.discardWorkingTree(path: "README.md",
                                                  repo: repoURL)
        guard case .ok = result else { XCTFail("\(result)"); return }
        let rows = try fetchStatus()
        XCTAssertTrue(rows.isEmpty,
                      "expected clean tree after discard, got \(rows)")
        let onDisk = try String(contentsOf: readmeURL(), encoding: .utf8)
        XCTAssertEqual(onDisk, "initial\n")
    }

    func test_stage_unstage_areIdempotent() async throws {
        // Repeated stage on an unmodified file is a no-op (git
        // returns success without touching the index). Same for
        // unstage on an already-clean file. We pin this so the
        // sidebar's "click stage twice" case stays smooth.
        XCTAssertEqual(GitClient.stage(path: "README.md", repo: repoURL),
                       .ok)
        XCTAssertEqual(GitClient.stage(path: "README.md", repo: repoURL),
                       .ok)
        XCTAssertEqual(GitClient.unstage(path: "README.md", repo: repoURL),
                       .ok)
    }

    // MARK: - Phase 35b-2b · commit / branch / amend

    func test_commit_recordsNewHEADAndClearsStaged() async throws {
        // Stage an edit, commit it, expect a clean working tree and
        // the new HEAD subject to match what we passed in.
        try seedFile(name: "README.md", contents: "edited\n")
        XCTAssertEqual(GitClient.stage(path: "README.md", repo: repoURL),
                       .ok)
        let result = GitClient.commit(message: "edit readme",
                                      repo: repoURL,
                                      amend: false)
        XCTAssertEqual(result, .ok, "commit failed: \(result)")
        XCTAssertTrue(try fetchStatus().isEmpty,
                      "tree should be clean after commit")
        XCTAssertEqual(GitClient.headSubject(repo: repoURL),
                       "edit readme")
    }

    func test_amend_rewritesHEADWithoutNewCommit() async throws {
        // Stage a second commit, amend it, then verify only one new
        // ref exists past the seed commit. We use `git log --oneline`
        // count as the proxy for "did we accidentally make 2 commits".
        try seedFile(name: "README.md", contents: "edited\n")
        XCTAssertEqual(GitClient.stage(path: "README.md", repo: repoURL),
                       .ok)
        XCTAssertEqual(GitClient.commit(message: "first edit",
                                        repo: repoURL,
                                        amend: false),
                       .ok)
        // Now amend.
        XCTAssertEqual(GitClient.commit(message: "first edit (reworded)",
                                        repo: repoURL,
                                        amend: true),
                       .ok)
        XCTAssertEqual(GitClient.headSubject(repo: repoURL),
                       "first edit (reworded)")
        // Total commits: seed + 1 (amend doesn't bump count).
        let log = try captureGit(["log", "--oneline"])
        let lines = log.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2,
                       "amend should not create a new commit; got \(lines)")
    }

    func test_commit_passesUnicodeAndMultilineMessageThroughStdin() async throws {
        // Commit messages are piped through stdin specifically so
        // long / multibyte / multi-line bodies survive intact. Pin
        // that contract: a Chinese subject + Linux-kernel-style body
        // round-trips bit-perfect into HEAD.
        try seedFile(name: "README.md", contents: "edited\n")
        XCTAssertEqual(GitClient.stage(path: "README.md", repo: repoURL),
                       .ok)
        let body = """
        修复中文路径的渲染

        Closes #123
        Signed-off-by: Scribe Test <test@scribe.app>
        """
        XCTAssertEqual(GitClient.commit(message: body,
                                        repo: repoURL,
                                        amend: false),
                       .ok)
        XCTAssertEqual(GitClient.headSubject(repo: repoURL), body)
    }

    func test_currentBranch_returnsSeedBranch() async throws {
        // Default branch on a fresh `git init` depends on the user's
        // `init.defaultBranch` config (`main` for modern installs,
        // `master` for old). Whichever it is, the helper should
        // round-trip through `git branch --show-current`.
        let expected = try captureGit(["branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(GitClient.currentBranch(repo: repoURL), expected)
    }

    func test_currentBranch_isNilWhenDetached() async throws {
        // Move HEAD to the seed commit's SHA so the working state is
        // detached, then verify currentBranch is nil (the porcelain
        // returns empty in that mode).
        let sha = try captureGit(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["checkout", "--quiet", sha])
        XCTAssertNil(GitClient.currentBranch(repo: repoURL))
    }

    // MARK: - Phase 35b-2c · push / pull / fetch / aheadBehind

    /// Set up a local bare remote at `remoteURL`, point the test
    /// repo's `origin` at it, and push the seed commit so an
    /// upstream tracking ref exists. Returns the bare remote URL
    /// for cleanup.
    private func attachBareRemote() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-git-remote-\(UUID().uuidString).git")
        try FileManager.default.createDirectory(at: tmp,
                                                withIntermediateDirectories: true)
        // `--initial-branch` keeps the bare remote's HEAD aligned
        // with whatever the test repo's seed branch is, avoiding
        // "remote HEAD is ambiguous" warnings on first push.
        let seedBranch = try captureGit(["branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = Process()
        bare.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        bare.arguments = ["init", "--bare", "--quiet",
                          "--initial-branch=\(seedBranch)", tmp.path]
        try bare.run()
        bare.waitUntilExit()
        XCTAssertEqual(bare.terminationStatus, 0)

        try runGit(["remote", "add", "origin", tmp.path])
        try runGit(["push", "--quiet", "-u", "origin", seedBranch])
        return tmp
    }

    func test_aheadBehind_isZeroAfterFreshPush() async throws {
        let bare = try attachBareRemote()
        defer { try? FileManager.default.removeItem(at: bare) }
        let ab = GitClient.aheadBehind(repo: repoURL)
        XCTAssertEqual(ab, GitClient.AheadBehind(ahead: 0, behind: 0))
    }

    func test_aheadBehind_isNilWithoutUpstream() async throws {
        // No remote attached → rev-list errors out → we expect nil
        // (which the sidebar interprets as "hide the chip").
        XCTAssertNil(GitClient.aheadBehind(repo: repoURL))
    }

    func test_push_drainsAheadCount() async throws {
        let bare = try attachBareRemote()
        defer { try? FileManager.default.removeItem(at: bare) }

        // Build one local commit on top of the seed.
        try seedFile(name: "README.md", contents: "edited\n")
        XCTAssertEqual(GitClient.stage(path: "README.md", repo: repoURL),
                       .ok)
        XCTAssertEqual(GitClient.commit(message: "edit",
                                        repo: repoURL,
                                        amend: false),
                       .ok)
        XCTAssertEqual(GitClient.aheadBehind(repo: repoURL),
                       GitClient.AheadBehind(ahead: 1, behind: 0))

        // Push and expect ahead → 0.
        XCTAssertEqual(GitClient.push(repo: repoURL), .ok)
        XCTAssertEqual(GitClient.aheadBehind(repo: repoURL),
                       GitClient.AheadBehind(ahead: 0, behind: 0))
    }

    // MARK: - Phase 35b-3-i · per-hunk apply round-trip

    func test_diffForApply_returnsHunksWithContext() async throws {
        // -U3 must include 3 surrounding context lines so a hunk
        // can be located by `git apply` even after an earlier hunk
        // has shifted line numbers. Pin that contract: a single-
        // line edit in the middle of the file should produce a
        // hunk whose body has at least one ' ' context line on
        // each side of the '+'/'-' pair.
        try seedFile(name: "src.txt", contents: """
        line 1
        line 2
        line 3
        line 4
        line 5
        line 6
        line 7
        line 8
        """)
        // Commit the seed so HEAD has src.txt; the tests above
        // already committed README.md but our seedFile helper
        // doesn't auto-commit. We need src.txt at HEAD before we
        // can diff a working-tree edit against it.
        try runGit(["add", "src.txt"])
        try runGit(["-c", "user.email=t@s.app", "-c", "user.name=T",
                    "commit", "-m", "seed src.txt", "--quiet"])
        // Edit one line in the middle; -U3 should show 3 ctx
        // lines on each side.
        try seedFile(name: "src.txt", contents: """
        line 1
        line 2
        line 3
        line 4 modified
        line 5
        line 6
        line 7
        line 8
        """)
        let result = GitClient.diffForApply(path: "src.txt",
                                            repo: repoURL,
                                            cached: false)
        guard case .diff(let raw) = result else {
            XCTFail("diffForApply did not return .diff: \(result)")
            return
        }
        let hunks = GitClient.parseHunks(raw)
        XCTAssertEqual(hunks.count, 1)
        let body = hunks[0].bodyLines
        // Count ' ' context lines vs '+'/'-' edits.
        let context = body.filter { $0.first == " " }
        let pluses  = body.filter { $0.first == "+" }
        let minuses = body.filter { $0.first == "-" }
        XCTAssertEqual(pluses.count, 1)
        XCTAssertEqual(minuses.count, 1)
        XCTAssertGreaterThanOrEqual(context.count, 6,
                                    "expected at least 3 ctx lines on each side; got \(context.count)")
    }

    func test_applyPatch_stagesSingleHunkOnly() async throws {
        // Two independent edits in the same file — make sure that
        // applying just one hunk to the index leaves the other
        // working-tree change unstaged. This is the smoke test for
        // the per-hunk stage UX: hover [+] on hunk 1 should not
        // collapse to "stage everything".
        try seedFile(name: "src.txt", contents: (1...20).map { "line \($0)" }
                     .joined(separator: "\n") + "\n")
        try runGit(["add", "src.txt"])
        try runGit(["-c", "user.email=t@s.app", "-c", "user.name=T",
                    "commit", "-m", "seed", "--quiet"])

        var lines = (1...20).map { "line \($0)" }
        lines[2] = "line 3 EDITED"      // hunk near top
        lines[15] = "line 16 EDITED"    // hunk near bottom
        try seedFile(name: "src.txt", contents: lines.joined(separator: "\n") + "\n")

        let diff = GitClient.diffForApply(path: "src.txt",
                                          repo: repoURL,
                                          cached: false)
        guard case .diff(let raw) = diff else {
            XCTFail("diff failed: \(diff)"); return
        }
        let hunks = GitClient.parseHunks(raw)
        XCTAssertEqual(hunks.count, 2,
                       "two distant edits should yield two hunks: \(raw)")

        // Stage just the first hunk.
        let patch = hunks[0].minimalPatch(forFilePath: "src.txt")
        XCTAssertEqual(GitClient.applyPatch(patch, repo: repoURL, reverse: false),
                       .ok)

        // After staging hunk 1: cached diff has 1 hunk (the edit
        // we just staged); working-tree-vs-index diff has 1 hunk
        // (the edit we left).
        guard case .diff(let cachedRaw) = GitClient.diffForApply(
                path: "src.txt", repo: repoURL, cached: true) else {
            XCTFail("cached diff failed"); return
        }
        guard case .diff(let workingRaw) = GitClient.diffForApply(
                path: "src.txt", repo: repoURL, cached: false) else {
            XCTFail("working diff failed"); return
        }
        XCTAssertEqual(GitClient.parseHunks(cachedRaw).count, 1,
                       "cached diff should hold the staged hunk: \(cachedRaw)")
        XCTAssertEqual(GitClient.parseHunks(workingRaw).count, 1,
                       "working diff should hold the un-staged hunk: \(workingRaw)")
    }

    func test_applyPatch_reverseUnstagesSingleHunkOnly() async throws {
        // Mirror of test_applyPatch_stagesSingleHunkOnly but
        // unstage-first: stage everything, then reverse-apply one
        // cached hunk to peel just that hunk back into the working
        // tree.
        try seedFile(name: "src.txt", contents: (1...20).map { "line \($0)" }
                     .joined(separator: "\n") + "\n")
        try runGit(["add", "src.txt"])
        try runGit(["-c", "user.email=t@s.app", "-c", "user.name=T",
                    "commit", "-m", "seed", "--quiet"])

        var lines = (1...20).map { "line \($0)" }
        lines[2] = "line 3 EDITED"
        lines[15] = "line 16 EDITED"
        try seedFile(name: "src.txt", contents: lines.joined(separator: "\n") + "\n")

        // Stage everything.
        XCTAssertEqual(GitClient.stage(path: "src.txt", repo: repoURL), .ok)

        // Pull the cached hunks and reverse-apply hunk 0.
        guard case .diff(let raw) = GitClient.diffForApply(
                path: "src.txt", repo: repoURL, cached: true) else {
            XCTFail("cached diff failed"); return
        }
        let hunks = GitClient.parseHunks(raw)
        XCTAssertEqual(hunks.count, 2)
        let patch = hunks[0].minimalPatch(forFilePath: "src.txt")
        XCTAssertEqual(GitClient.applyPatch(patch, repo: repoURL, reverse: true),
                       .ok)

        // After reverse-apply: cached has 1 hunk (the one we left),
        // working-tree-vs-index has 1 hunk (the one we peeled
        // back).
        guard case .diff(let cachedRaw) = GitClient.diffForApply(
                path: "src.txt", repo: repoURL, cached: true) else {
            XCTFail("cached diff failed"); return
        }
        guard case .diff(let workingRaw) = GitClient.diffForApply(
                path: "src.txt", repo: repoURL, cached: false) else {
            XCTFail("working diff failed"); return
        }
        XCTAssertEqual(GitClient.parseHunks(cachedRaw).count, 1)
        XCTAssertEqual(GitClient.parseHunks(workingRaw).count, 1)
    }

    // MARK: - Phase 35b-2c · push / pull / fetch round-trip (continued)

    func test_pull_fastForwardsBehindCount() async throws {
        let bare = try attachBareRemote()
        defer { try? FileManager.default.removeItem(at: bare) }
        let seedBranch = try captureGit(["branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Simulate "another clone pushed a commit" by cloning the
        // bare remote into a sibling, committing there, and pushing
        // back. Our local repo will then be 1 behind.
        let sibling = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-git-sibling-\(UUID().uuidString)")
        try runGitGlobal(["clone", "--quiet", bare.path, sibling.path])
        defer { try? FileManager.default.removeItem(at: sibling) }
        try "remote-edit\n".write(to: sibling.appendingPathComponent("README.md"),
                                  atomically: true, encoding: .utf8)
        try runGitIn(sibling, ["add", "README.md"])
        try runGitIn(sibling, ["-c", "user.email=t@s.app",
                               "-c", "user.name=T",
                               "commit", "-m", "remote edit", "--quiet"])
        try runGitIn(sibling, ["push", "--quiet", "origin", seedBranch])

        // Local hasn't fetched yet — aheadBehind only updates after
        // a fetch because that's where the remote-tracking ref moves.
        XCTAssertEqual(GitClient.fetch(repo: repoURL), .ok)
        XCTAssertEqual(GitClient.aheadBehind(repo: repoURL),
                       GitClient.AheadBehind(ahead: 0, behind: 1))

        // Pull (fast-forward) drains behind to 0.
        XCTAssertEqual(GitClient.pull(repo: repoURL), .ok)
        XCTAssertEqual(GitClient.aheadBehind(repo: repoURL),
                       GitClient.AheadBehind(ahead: 0, behind: 0))
    }

    // MARK: - Phase 35b-4-a · branches & force-with-lease

    func test_branches_listsLocalCurrentAndUpstream() async throws {
        // Bare remote attaches `origin/<seedBranch>` and seed
        // commits already exist. After attachBareRemote the local
        // branch tracks origin/<seedBranch>, so `branches(repo:)`
        // should report:
        //   - 1 local branch, isCurrent = true, upstream non-nil
        //   - 1 remote-tracking branch (origin/<seedBranch>),
        //     isRemote = true
        // Plus we filter out origin/HEAD (a symref).
        let bare = try attachBareRemote()
        defer { try? FileManager.default.removeItem(at: bare) }
        let seedBranch = try captureGit(["branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let branches = GitClient.branches(repo: repoURL)

        let local = branches.filter { !$0.isRemote }
        XCTAssertEqual(local.count, 1)
        XCTAssertEqual(local[0].name, seedBranch)
        XCTAssertTrue(local[0].isCurrent)
        XCTAssertEqual(local[0].upstream, "origin/\(seedBranch)")

        let remote = branches.filter { $0.isRemote }
        // Exactly the one tracking ref, no origin/HEAD symref.
        XCTAssertEqual(remote.count, 1, "branches: \(branches)")
        XCTAssertEqual(remote[0].name, "origin/\(seedBranch)")
        XCTAssertFalse(remote[0].isCurrent)
    }

    func test_branches_marksOnlyOneCurrent() async throws {
        // After creating a second local branch (no checkout),
        // exactly one branch must carry isCurrent. Pin the
        // %(HEAD) "*"-only contract end-to-end.
        try runGit(["branch", "feature"])
        let branches = GitClient.branches(repo: repoURL)
        let currents = branches.filter { $0.isCurrent }
        XCTAssertEqual(currents.count, 1)
        XCTAssertEqual(branches.count, 2,
                       "expected the new feature branch to appear: \(branches)")
    }

    func test_checkoutBranch_switchesToLocal() async throws {
        // Create a local branch, switch to it via GitClient,
        // verify HEAD moves.
        try runGit(["branch", "feature"])
        let target = GitClient.Branch(name: "feature",
                                      isCurrent: false,
                                      isRemote: false,
                                      upstream: nil)
        XCTAssertEqual(GitClient.checkoutBranch(target, repo: repoURL),
                       .ok)
        let now = try captureGit(["branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(now, "feature")
    }

    func test_checkoutBranch_remote_autoCreatesTrackingLocal() async throws {
        // Sibling pushes a new branch "ext-feature" to the bare
        // remote. After fetch, our repo should see
        // refs/remotes/origin/ext-feature but NO local
        // ext-feature. Calling checkoutBranch on the remote ref
        // should auto-create the local tracking branch.
        let bare = try attachBareRemote()
        defer { try? FileManager.default.removeItem(at: bare) }

        // Bring up a sibling that pushes an extra branch.
        let sibling = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-git-sibling-\(UUID().uuidString)")
        try runGitGlobal(["clone", "--quiet", bare.path, sibling.path])
        defer { try? FileManager.default.removeItem(at: sibling) }
        try runGitIn(sibling, ["checkout", "-b", "ext-feature"])
        try "ext\n".write(to: sibling.appendingPathComponent("EXT.txt"),
                          atomically: true, encoding: .utf8)
        try runGitIn(sibling, ["add", "EXT.txt"])
        try runGitIn(sibling, ["-c", "user.email=t@s.app",
                               "-c", "user.name=T",
                               "commit", "-m", "ext", "--quiet"])
        try runGitIn(sibling, ["push", "--quiet", "-u",
                               "origin", "ext-feature"])

        // Local repo fetches and sees the new remote-tracking ref.
        XCTAssertEqual(GitClient.fetch(repo: repoURL), .ok)
        let remoteRef = GitClient.Branch(name: "origin/ext-feature",
                                         isCurrent: false,
                                         isRemote: true,
                                         upstream: nil)
        XCTAssertEqual(GitClient.checkoutBranch(remoteRef, repo: repoURL),
                       .ok)
        // After the auto-tracking switch, HEAD should be on a
        // local branch named "ext-feature" (not detached, not
        // origin/ext-feature).
        let head = try captureGit(["branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(head, "ext-feature")
    }

    func test_pushForceWithLease_acceptsWhenLeaseIsCurrent() async throws {
        // Lease passes when our notion of the remote ref matches
        // the actual remote ref — the normal "I just pulled and
        // amended" workflow. Stage an amend on top of the seed
        // and force-with-lease push it.
        let bare = try attachBareRemote()
        defer { try? FileManager.default.removeItem(at: bare) }

        try seedFile(name: "README.md", contents: "amended\n")
        XCTAssertEqual(GitClient.stage(path: "README.md", repo: repoURL),
                       .ok)
        XCTAssertEqual(
            GitClient.commit(message: "amended", repo: repoURL, amend: true),
            .ok
        )
        // Plain push would be rejected (non-fast-forward) because
        // amend rewrote history. force-with-lease is the right
        // tool here.
        XCTAssertEqual(GitClient.pushForceWithLease(repo: repoURL),
                       .ok)
    }

    func test_pushForceWithLease_rejectsWhenLeaseIsStale() async throws {
        // Lease fails when the remote ref has moved since our
        // last fetch — a teammate pushed something we haven't
        // seen yet. Pin the safety contract: the call returns
        // .error rather than overwriting the teammate's commit.
        let bare = try attachBareRemote()
        defer { try? FileManager.default.removeItem(at: bare) }
        let seedBranch = try captureGit(["branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Sibling pushes a new commit to the remote.
        let sibling = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-git-sibling-\(UUID().uuidString)")
        try runGitGlobal(["clone", "--quiet", bare.path, sibling.path])
        defer { try? FileManager.default.removeItem(at: sibling) }
        try "teammate\n".write(to: sibling.appendingPathComponent("README.md"),
                               atomically: true, encoding: .utf8)
        try runGitIn(sibling, ["add", "README.md"])
        try runGitIn(sibling, ["-c", "user.email=t@s.app",
                               "-c", "user.name=T",
                               "commit", "-m", "teammate edit", "--quiet"])
        try runGitIn(sibling, ["push", "--quiet", "origin", seedBranch])

        // We didn't fetch — local origin/<seedBranch> still points
        // at the seed commit. Now we amend locally and try to
        // force-with-lease push: lease is stale ⇒ git refuses.
        try seedFile(name: "README.md", contents: "local\n")
        XCTAssertEqual(GitClient.stage(path: "README.md", repo: repoURL),
                       .ok)
        XCTAssertEqual(
            GitClient.commit(message: "local edit", repo: repoURL, amend: true),
            .ok
        )
        let result = GitClient.pushForceWithLease(repo: repoURL)
        guard case .error = result else {
            XCTFail("expected lease rejection, got: \(result)")
            return
        }
    }

    // MARK: - Phase 35b-4-b · projectDiff() multibuffer payload

    func test_projectDiff_returnsEmptyOnCleanRepo() async throws {
        // Seed-only repo, no edits. projectDiff() walks the rows
        // list, which is empty here, so the result is empty
        // regardless of `repo == nil` short-circuiting. Pin the
        // "no rows ⇒ no entries" path so a later refactor that
        // accidentally reaches into `git status` directly still
        // returns the same empty.
        let engine = GitStatusEngine()
        engine.bind(repo: repoURL)
        try await waitForEngineLoaded(engine)
        let entries = await engine.projectDiff()
        XCTAssertEqual(entries, [])
    }

    func test_projectDiff_includesWorkingHunksOnly() async throws {
        // Edit-without-stage → `git diff` shows the hunk in the
        // working column, `git diff --cached` shows nothing.
        // projectDiff() must reflect that asymmetry: stagedHunks
        // empty, workingHunks non-empty.
        try seedFile(name: "README.md", contents: "edited\n")
        let engine = GitStatusEngine()
        engine.bind(repo: repoURL)
        try await waitForEngineLoaded(engine)
        let entries = await engine.projectDiff()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "README.md")
        XCTAssertTrue(entries[0].stagedHunks.isEmpty)
        XCTAssertFalse(entries[0].workingHunks.isEmpty)
    }

    func test_projectDiff_includesStagedHunksOnly() async throws {
        // Edit + stage → working column is clean again (the edit
        // moved into the index), staged column has the hunk.
        try seedFile(name: "README.md", contents: "edited\n")
        XCTAssertEqual(GitClient.stage(path: "README.md", repo: repoURL),
                       .ok)
        let engine = GitStatusEngine()
        engine.bind(repo: repoURL)
        try await waitForEngineLoaded(engine)
        let entries = await engine.projectDiff()
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].stagedHunks.isEmpty)
        XCTAssertTrue(entries[0].workingHunks.isEmpty)
    }

    func test_projectDiff_includesBothWhenMixed() async throws {
        // Edit + stage, then edit again before commit → file is
        // simultaneously "different in index vs HEAD" and
        // "different in working tree vs index". Both hunk lists
        // populate. Pin the contract because the multibuffer view
        // surfaces them as two visually-distinct strips per file.
        try seedFile(name: "README.md", contents: "edited\n")
        XCTAssertEqual(GitClient.stage(path: "README.md", repo: repoURL),
                       .ok)
        try seedFile(name: "README.md", contents: "edited again\n")
        let engine = GitStatusEngine()
        engine.bind(repo: repoURL)
        try await waitForEngineLoaded(engine)
        let entries = await engine.projectDiff()
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].stagedHunks.isEmpty)
        XCTAssertFalse(entries[0].workingHunks.isEmpty)
    }

    func test_projectDiff_skipsUntrackedFiles() async throws {
        // Untracked files show up in `git status` but `git diff`
        // produces nothing for them (no base to diff against). The
        // engine drops the resulting empty entry — otherwise the
        // multibuffer would render an empty file section that
        // can't be acted on.
        try seedFile(name: "newfile.txt", contents: "hello\n")
        let engine = GitStatusEngine()
        engine.bind(repo: repoURL)
        try await waitForEngineLoaded(engine)
        let entries = await engine.projectDiff()
        XCTAssertEqual(entries, [],
                       "untracked file should not appear in projectDiff: \(entries)")
    }

    // MARK: - Phase 35b-4-d · revert one working-tree hunk

    func test_revertHunk_removesWorkingChange() async throws {
        // Edit a file (no stage), grab the working hunk, then
        // revertHunk via the engine. After: working tree clean,
        // index clean (we never staged), HEAD blob unchanged.
        try seedFile(name: "README.md",
                     contents: "line1\nline2-edited\nline3\n")
        let engine = GitStatusEngine()
        engine.bind(repo: repoURL)
        try await waitForEngineLoaded(engine)
        let hunks = await engine.hunks(forPath: "README.md", cached: false)
        XCTAssertEqual(hunks.count, 1, "expected one working hunk")
        await engine.revertHunk(hunks[0], path: "README.md")
        let workingAfter = await engine.hunks(forPath: "README.md", cached: false)
        let stagedAfter  = await engine.hunks(forPath: "README.md", cached: true)
        XCTAssertTrue(workingAfter.isEmpty,
                      "revert should leave working tree clean: \(workingAfter)")
        XCTAssertTrue(stagedAfter.isEmpty,
                      "index untouched, should still match HEAD")
    }

    func test_applyPatch_workingTreeReverseRemovesEdit() async throws {
        // Direct GitClient.applyPatch contract test for the
        // `cached: false` extension landed in Phase 35b-4-d. We
        // need the patch shape to be exactly what `git diff` emitted
        // for the working tree, otherwise reverse-apply can't find
        // the slice.
        try seedFile(name: "README.md", contents: "edited\n")
        let diff = GitClient.diffForApply(path: "README.md",
                                          repo: repoURL,
                                          cached: false)
        guard case .diff(let raw) = diff else {
            XCTFail("expected diff, got: \(diff)"); return
        }
        let parsed = GitClient.parseHunks(raw)
        XCTAssertEqual(parsed.count, 1)
        let patch = parsed[0].minimalPatch(forFilePath: "README.md")
        let result = GitClient.applyPatch(patch, repo: repoURL,
                                          reverse: true, cached: false)
        XCTAssertEqual(result, .ok)
        // After reverse-apply the working tree is HEAD again — re-
        // diff returns nothing.
        let after = GitClient.diffForApply(path: "README.md",
                                           repo: repoURL, cached: false)
        if case .diff(let raw) = after {
            XCTAssertTrue(raw.isEmpty,
                          "working tree should be clean: \(raw)")
        }
    }

    // MARK: - Phase 35b-4-c · path-keyed stage / unstage helpers

    func test_stagePath_movesWorkingChangeIntoIndex() async throws {
        // Edit, no stage. After stagePath, `git diff` (working
        // vs index) is empty and `git diff --cached` reports the
        // hunk — i.e. the change has crossed the index.
        try seedFile(name: "README.md", contents: "edited\n")
        let engine = GitStatusEngine()
        engine.bind(repo: repoURL)
        try await waitForEngineLoaded(engine)
        await engine.stagePath("README.md")
        let working = await engine.hunks(forPath: "README.md", cached: false)
        let staged  = await engine.hunks(forPath: "README.md", cached: true)
        XCTAssertTrue(working.isEmpty,
                      "working tree should be clean after stagePath: \(working)")
        XCTAssertFalse(staged.isEmpty,
                       "staged column should now hold the hunk")
    }

    func test_unstagePath_movesIndexChangeBackToWorking() async throws {
        // Stage a working edit, then unstage by path. After-
        // wards the index matches HEAD again and the working
        // tree carries the hunk — symmetric to the stagePath
        // contract.
        try seedFile(name: "README.md", contents: "edited\n")
        XCTAssertEqual(GitClient.stage(path: "README.md", repo: repoURL),
                       .ok)
        let engine = GitStatusEngine()
        engine.bind(repo: repoURL)
        try await waitForEngineLoaded(engine)
        await engine.unstagePath("README.md")
        let working = await engine.hunks(forPath: "README.md", cached: false)
        let staged  = await engine.hunks(forPath: "README.md", cached: true)
        XCTAssertFalse(working.isEmpty,
                       "working tree should hold the hunk after unstagePath")
        XCTAssertTrue(staged.isEmpty,
                      "staged column should be clean")
    }

    func test_stagePath_isNoOpForUnknownPath() async throws {
        // Lookup miss (path that no row reports) silently
        // returns. We don't surface an error because the
        // multibuffer always reloads after the action and a
        // vanished row simply won't reappear; pinning the
        // contract here so a later refactor doesn't regress
        // into popping an alert.
        try seedFile(name: "README.md", contents: "edited\n")
        let engine = GitStatusEngine()
        engine.bind(repo: repoURL)
        try await waitForEngineLoaded(engine)
        await engine.stagePath("does/not/exist.txt")
        // README is still working-only — engine state untouched.
        let staged = await engine.hunks(forPath: "README.md", cached: true)
        XCTAssertTrue(staged.isEmpty)
    }

    /// Spin-wait until the engine reports `.loaded`. We use an
    /// active poll rather than wiring up a Combine sink because
    /// `GitStatusEngine.refresh()` always reaches a terminal
    /// state (`.loaded`, `.notInRepo`, or `.idle`) within a few
    /// hundred ms in practice; spinning at 25ms cadence keeps
    /// the test cost negligible while staying robust to
    /// scheduler jitter.
    private func waitForEngineLoaded(_ engine: GitStatusEngine,
                                     timeoutMs: Int = 3_000) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while engine.state != .loaded {
            if Date() > deadline {
                XCTFail("GitStatusEngine never reached .loaded "
                        + "(last state: \(engine.state))")
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// Run a git invocation in `cwd`. Used by the pull test which
    /// needs to drive a sibling clone in addition to `repoURL`.
    private func runGitIn(_ cwd: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    /// `git <args>` with no cwd — used for `git clone` where the
    /// destination is the argument rather than the current dir.
    private func runGitGlobal(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    /// Capture stdout from a git invocation. Used by tests that
    /// need the raw output (commit log, sha, branch lookup) rather
    /// than just exit-status handling.
    private func captureGit(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repoURL
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Phase 35c-i · git blame round-trips

    func test_blame_initialCommit_returnsAuthorAndCurrentSha() async throws {
        // The setUp commit creates README.md with "initial\n" as
        // its only line. blame() should resolve it to one row
        // pointing at HEAD with the test identity baked in. We
        // pin sha against `git rev-parse HEAD` so the test
        // doesn't drift if setUp's commit message ever changes.
        let head = try captureGit(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = GitClient.blame(file: readmeURL())
        guard case .ok(let lines) = result else {
            XCTFail("expected .ok, got: \(result)"); return
        }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].lineNo, 1)
        XCTAssertEqual(lines[0].sha, head)
        XCTAssertEqual(lines[0].author, "Scribe Test")
        XCTAssertEqual(lines[0].authorEmail, "<test@scribe.app>")
        XCTAssertEqual(lines[0].summary, "initial")
        XCTAssertFalse(lines[0].isUncommitted)
        // authorTime came from `git commit` clock; just sanity-
        // check it's a positive Unix timestamp rather than 0.
        XCTAssertGreaterThan(lines[0].authorTime, 0)
    }

    func test_blame_workingChange_marksLineUncommitted() async throws {
        // Append a line in the working tree (no stage, no commit).
        // git blame's porcelain emits the all-zeros SHA for it,
        // which BlameLine.isUncommitted picks up. The original
        // line still resolves to HEAD.
        try seedFile(name: "README.md", contents: "initial\nadded\n")
        let result = GitClient.blame(file: readmeURL())
        guard case .ok(let lines) = result else {
            XCTFail("expected .ok, got: \(result)"); return
        }
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[0].isUncommitted,
                       "line 1 should still be the HEAD commit")
        XCTAssertTrue(lines[1].isUncommitted,
                      "line 2 is a fresh working-tree edit")
    }

    func test_blame_untrackedFile_returnsUntracked() async throws {
        // A file that exists on disk but isn't in the index has
        // no blame surface at all. Mirroring headBlob's contract
        // so the inline-blame UI can collapse both cases to "no
        // annotations" without a special branch.
        try seedFile(name: "scratch.txt", contents: "hi\n")
        let url = repoURL.appendingPathComponent("scratch.txt")
        let result = GitClient.blame(file: url)
        if case .untracked = result {
            // expected
        } else {
            XCTFail("expected .untracked, got: \(result)")
        }
    }

    func test_blame_outsideRepo_returnsNotInRepo() async throws {
        // Pick a path that has no .git ancestor. macOS
        // /private/tmp is reliably outside any repo on a CI
        // runner, and createDirectory makes setUp's repoURL its
        // sibling rather than parent.
        let outside = URL(fileURLWithPath: "/private/tmp/scribe-not-a-repo-\(UUID().uuidString).txt")
        try "x\n".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let result = GitClient.blame(file: outside)
        if case .notInRepo = result {
            // expected
        } else {
            XCTFail("expected .notInRepo, got: \(result)")
        }
    }

    // MARK: - Phase 35c-ii-β · GitBlameEngine round-trips

    func test_blameEngine_request_populatesCacheForTrackedFile() async throws {
        // request(for:) hops to a detached task that shells out
        // to `git blame --porcelain`; the parsed [Int: BlameLine]
        // map lands on `blameByURL[url]` once the task hops back
        // to main. Pin the round-trip so a future refactor can't
        // silently break the engine's only consumer contract.
        let engine = GitBlameEngine()
        engine.request(for: readmeURL())
        try await waitForBlame(engine: engine, url: readmeURL())
        let line1 = engine.blameLine(for: readmeURL(), line: 1)
        XCTAssertNotNil(line1)
        XCTAssertEqual(line1?.author, "Scribe Test")
        XCTAssertFalse(line1?.isUncommitted ?? true)
    }

    func test_blameEngine_request_isCacheHitOnSecondCall() async throws {
        // The second call within the same engine lifetime must
        // be a no-op — cache hit means the inline-blame UI's
        // "tab switch back to a file we just blamed" path is
        // free, no shell-out fan-out.
        let engine = GitBlameEngine()
        engine.request(for: readmeURL())
        try await waitForBlame(engine: engine, url: readmeURL())
        let snapshot = engine.blameByURL[readmeURL().standardizedFileURL]
        // Re-request: cache hit should keep the *exact same*
        // dictionary instance (no mutation, no replace).
        engine.request(for: readmeURL())
        // Brief grace window so any *spurious* spawn would have
        // landed by now; the cache entry should still equal the
        // original snapshot.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.blameByURL[readmeURL().standardizedFileURL],
                       snapshot,
                       "cache hit must not re-fetch")
    }

    func test_blameEngine_refresh_replacesCacheAfterEdit() async throws {
        // After a working-tree edit (no commit), refresh(for:)
        // re-blames and the new line shows up with the all-
        // zeros uncommitted SHA. This is the path Workspace
        // calls on save / external change.
        let engine = GitBlameEngine()
        engine.request(for: readmeURL())
        try await waitForBlame(engine: engine, url: readmeURL())
        XCTAssertEqual(engine.blameByURL[readmeURL().standardizedFileURL]?.count, 1)

        try seedFile(name: "README.md", contents: "initial\nadded\n")
        engine.refresh(for: readmeURL())
        // Cache cleared synchronously by refresh; wait for the
        // re-fetch to land.
        try await waitForBlame(engine: engine, url: readmeURL())
        let map = engine.blameByURL[readmeURL().standardizedFileURL]
        XCTAssertEqual(map?.count, 2)
        XCTAssertEqual(map?[2]?.isUncommitted, true)
    }

    func test_blameEngine_invalidateAll_dropsEveryEntry() async throws {
        // Folder switch should drop every cached row so the new
        // folder doesn't see stale rows for the same paths. The
        // engine doesn't auto-refetch — it waits for the next
        // explicit request().
        let engine = GitBlameEngine()
        engine.request(for: readmeURL())
        try await waitForBlame(engine: engine, url: readmeURL())
        XCTAssertFalse(engine.blameByURL.isEmpty)

        engine.invalidateAll()
        XCTAssertTrue(engine.blameByURL.isEmpty)
    }

    func test_blameEngine_untrackedURL_storesEmptyMapNotNil() async throws {
        // .untracked / .notInRepo land an empty map (not nil)
        // so the inline-blame UI knows we asked, the answer is
        // nothing, and stops re-requesting on every caret tick.
        try seedFile(name: "scratch.txt", contents: "hi\n")
        let url = repoURL.appendingPathComponent("scratch.txt")
        let engine = GitBlameEngine()
        engine.request(for: url)
        // For untracked the engine's map ends up explicitly empty;
        // wait until it transitions out of "not yet asked" (nil)
        // to "asked, empty" ([:]).
        try await waitForBlame(engine: engine,
                               url: url,
                               allowEmpty: true)
        let map = engine.blameByURL[url.standardizedFileURL]
        XCTAssertNotNil(map, "engine should pin asked-and-empty")
        XCTAssertTrue(map?.isEmpty ?? false)
    }

    /// Spin until `engine.blameByURL[url]` is non-nil. Default
    /// requires at least one BlameLine to land; pass
    /// `allowEmpty: true` for the untracked / not-in-repo cases
    /// where the engine pins an empty dictionary.
    private func waitForBlame(engine: GitBlameEngine,
                              url: URL,
                              allowEmpty: Bool = false,
                              timeoutMs: Int = 3_000) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        let key = url.standardizedFileURL
        while true {
            if let map = engine.blameByURL[key] {
                if allowEmpty || !map.isEmpty { return }
            }
            if Date() > deadline {
                XCTFail("GitBlameEngine never populated \(key) "
                        + "(allowEmpty: \(allowEmpty))")
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    // MARK: - Helpers

    /// Run a git invocation against `repoURL`. Throws on non-zero
    /// exit so a failed setup is visible at its origin instead of
    /// surfacing as a confusing parse error downstream.
    private func runGit(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repoURL
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func seedFile(name: String, contents: String) throws {
        let url = repoURL.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readmeURL() -> URL {
        repoURL.appendingPathComponent("README.md")
    }

    private func fetchStatus() throws -> [GitFileStatus] {
        switch GitClient.status(repo: repoURL) {
        case .rows(let r): return r
        case .notInRepo, .error(_):
            throw NSError(domain: "scribe", code: 1)
        }
    }
}

