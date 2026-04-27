//
//  GitClientTests.swift
//  Phase 8 — exercises GitClient against a freshly-initialised
//  throw-away git repo. We invoke the real /usr/bin/git so the tests
//  cover the actual path Scribe uses; the repos live in NSTemporary
//  and are torn down in tearDown.
//

import XCTest
@testable import Scribe

final class GitClientTests: XCTestCase {

    private var repoRoot: URL!

    override func setUpWithError() throws {
        let raw = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-gitclient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw,
                                                withIntermediateDirectories: true)
        repoRoot = raw.resolvingSymlinksInPath()

        // git init + identity + initial commit so HEAD is valid.
        try gitInit()
        try setIdentity()
        try writeFile("README.md", "# initial\n")
        try gitAdd(".")
        try gitCommit("initial")
    }

    override func tearDownWithError() throws {
        if let repoRoot {
            try? FileManager.default.removeItem(at: repoRoot)
        }
    }

    // MARK: - Tests

    func test_findRepoRoot_locatesGitDirectory() throws {
        try writeFile("nested/deep/file.swift", "x")
        let nested = repoRoot.appendingPathComponent("nested/deep/file.swift")
        let root = GitClient.findRepoRoot(for: nested)
        XCTAssertEqual(root?.path, repoRoot.path)
    }

    func test_findRepoRoot_returnsNilOutsideRepo() throws {
        let outside = URL(fileURLWithPath: "/tmp/definitely-not-in-a-repo")
        XCTAssertNil(GitClient.findRepoRoot(for: outside))
    }

    func test_headBlob_returnsCommittedContents() throws {
        // Commit v1, modify on disk, then headBlob should still return
        // the v1 contents.
        let path = "src/main.swift"
        try writeFile(path, "print(\"v1\")\n")
        try gitAdd(path)
        try gitCommit("add main")

        // Mutate working tree.
        try writeFile(path, "print(\"v2-uncommitted\")\n")

        let url = repoRoot.appendingPathComponent(path)
        let result = GitClient.headBlob(of: url)
        switch result {
        case .success(let blob, let shortSHA):
            XCTAssertEqual(blob, "print(\"v1\")\n")
            // 7-char hexadecimal SHA. Don't pin the exact value because
            // git's hashing depends on author timestamps.
            XCTAssertEqual(shortSHA.count, 7)
            XCTAssertTrue(shortSHA.allSatisfy { $0.isHexDigit })
        default:
            XCTFail("expected success, got \(result)")
        }
    }

    func test_headBlob_reportsUntrackedFile() throws {
        let path = "src/new.swift"
        try writeFile(path, "untracked\n")
        let url = repoRoot.appendingPathComponent(path)
        let result = GitClient.headBlob(of: url)
        if case .untracked = result {
            // ok
        } else {
            XCTFail("expected .untracked, got \(result)")
        }
    }

    func test_headBlob_reportsNotInRepo() {
        let outside = URL(fileURLWithPath: "/tmp/not-in-any-repo-xxxxxxx")
        let result = GitClient.headBlob(of: outside)
        if case .notInRepo = result {
            // ok
        } else {
            XCTFail("expected .notInRepo, got \(result)")
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func runGit(_ args: [String]) throws -> String {
        let task = Process()
        task.currentDirectoryURL = repoRoot
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = args
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        task.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "Test"
        env["GIT_AUTHOR_EMAIL"] = "test@example.com"
        env["GIT_COMMITTER_NAME"] = "Test"
        env["GIT_COMMITTER_EMAIL"] = "test@example.com"
        task.environment = env
        try task.run()
        task.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        if task.terminationStatus != 0 {
            throw NSError(domain: "git", code: Int(task.terminationStatus))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func gitInit() throws {
        try runGit(["init", "-q", "--initial-branch=main"])
    }

    private func setIdentity() throws {
        try runGit(["config", "user.email", "test@example.com"])
        try runGit(["config", "user.name", "Test User"])
    }

    private func gitAdd(_ pathspec: String) throws {
        try runGit(["add", "--", pathspec])
    }

    private func gitCommit(_ message: String) throws {
        try runGit(["commit", "-q", "-m", message])
    }

    private func writeFile(_ relPath: String, _ contents: String) throws {
        let url = repoRoot.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
    }
}
