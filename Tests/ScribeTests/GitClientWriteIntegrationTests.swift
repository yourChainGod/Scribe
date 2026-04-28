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

