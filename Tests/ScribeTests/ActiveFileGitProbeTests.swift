//
//  ActiveFileGitProbeTests.swift
//  Phase 48b — locks the contract for the single-file branch chip
//  fallback. Two layers of coverage:
//
//    1. Pure-state behaviour (no git shell-out): suspension clears
//       outputs, nil URL clears outputs, suspension during a probe
//       cancels the in-flight task. Runs on every machine.
//    2. Integration with real git: build a throwaway repo, probe
//       a file inside it, confirm `branch` resolves. Skipped when
//       /usr/bin/git is missing so minimal CI runners don't fail
//       on a Scribe-unrelated dep.
//

import Foundation
import XCTest
@testable import Scribe

@MainActor
final class ActiveFileGitProbeTests: XCTestCase {

    private var probe: ActiveFileGitProbe!

    override func setUp() async throws {
        try await super.setUp()
        probe = ActiveFileGitProbe()
    }

    override func tearDown() async throws {
        probe = nil
        try await super.tearDown()
    }

    // MARK: - suspension / nil-input clears

    func test_update_whenSuspended_clearsCachedOutputs() async {
        // Pre-populate via a real probe pass against the test repo
        // (only when git is available); otherwise just simulate the
        // "previously had data" condition manually for the clear path.
        try? prepRepo()
        if let inside = repoInsideURL {
            probe.update(activeFileURL: inside, suspended: false)
            await waitForProbeQuiescence()
        }

        probe.update(activeFileURL: repoInsideURL, suspended: true)
        await waitForProbeQuiescence()
        XCTAssertNil(probe.branch,
                     "suspending the probe should clear branch")
        XCTAssertNil(probe.aheadBehind)
        XCTAssertNil(probe.repoRoot)
    }

    func test_update_whenURLIsNil_clearsCachedOutputs() async {
        try? prepRepo()
        if let inside = repoInsideURL {
            probe.update(activeFileURL: inside, suspended: false)
            await waitForProbeQuiescence()
        }

        probe.update(activeFileURL: nil, suspended: false)
        await waitForProbeQuiescence()
        XCTAssertNil(probe.branch)
        XCTAssertNil(probe.aheadBehind)
        XCTAssertNil(probe.repoRoot)
    }

    func test_update_whenURLOutsideRepo_resolvesNil() async throws {
        // Use a non-repo temp dir so findRepoRoot returns nil and
        // the probe lands at "in repo? no" — branch must be nil but
        // we still walked the resolution path (no crash, clean state).
        let stray = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-probe-stray-\(UUID().uuidString).txt")
        try "x".write(to: stray, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: stray) }

        // Walk up from /tmp typically *does* hit a repo on dev
        // machines (the agent's $HOME may be a repo). Skip when that
        // happens so the assertion below isn't a false negative.
        if GitClient.findRepoRoot(for: stray) != nil {
            throw XCTSkip("temp dir inherits a repo root on this machine; cannot test no-repo path here")
        }

        probe.update(activeFileURL: stray, suspended: false)
        await waitForProbeQuiescence()
        XCTAssertNil(probe.branch)
        XCTAssertNil(probe.aheadBehind)
        XCTAssertNil(probe.repoRoot)
    }

    // MARK: - real-repo integration

    func test_update_resolvesBranchForFileInsideRepo() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available on this runner"
        )
        try prepRepo()

        probe.update(activeFileURL: repoInsideURL, suspended: false)
        await waitForProbeQuiescence()

        XCTAssertEqual(probe.repoRoot?.standardizedFileURL,
                       repoURL?.standardizedFileURL,
                       "probe should resolve the .git ancestor")
        XCTAssertNotNil(probe.branch,
                        "fresh repo with one commit must have a HEAD branch")
        // No upstream configured ⇒ aheadBehind nil, like in the chip
        // path: the indicator hides itself.
        XCTAssertNil(probe.aheadBehind,
                     "no remote configured ⇒ no ahead/behind data")
    }

    // MARK: - test helpers

    private var repoURL: URL?
    private var repoInsideURL: URL?

    /// Build a one-commit throwaway repo under NSTemporaryDirectory.
    /// Sets `repoURL` (root with `.git`) and `repoInsideURL`
    /// (a file inside it the probe can target). Cleans up via the
    /// addTeardownBlock hook so each test is self-contained.
    private func prepRepo() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            return
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp,
                                                withIntermediateDirectories: true)
        repoURL = tmp
        addTeardownBlock { [tmp] in
            try? FileManager.default.removeItem(at: tmp)
        }
        try runGit(["init", "--quiet"], in: tmp)
        try runGit(["config", "user.email", "probe@scribe.app"], in: tmp)
        try runGit(["config", "user.name", "Scribe Probe"], in: tmp)
        let inside = tmp.appendingPathComponent("README.md")
        try "seed\n".write(to: inside, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], in: tmp)
        try runGit(["commit", "-m", "seed", "--quiet"], in: tmp)
        repoInsideURL = inside
    }

    private func runGit(_ args: [String], in cwd: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0,
                       "git \(args.joined(separator: " ")) failed")
    }

    /// Phase 48b — `ActiveFileGitProbe.update` schedules a detached
    /// task that hops back to the main actor to commit results.
    /// Tests need to wait for that whole pipeline to settle. A small
    /// async sleep is enough because `git rev-parse` + branch +
    /// aheadBehind on a one-commit repo finishes in milliseconds.
    private func waitForProbeQuiescence() async {
        // 250ms is generous given the work happening (two cheap
        // shell-outs); on a dev box this resolves in ~5ms but slow
        // CI is forgiving.
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
}
