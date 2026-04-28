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

