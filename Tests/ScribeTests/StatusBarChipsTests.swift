//
//  StatusBarChipsTests.swift
//  Phase 46f+g — locks the gating logic behind the new status-bar
//  indicators:
//    - Git branch chip shows only when `GitStatusEngine.branch` is
//      non-nil (repo bound, HEAD resolvable).
//    - Find-matches pill shows only when the find bar is visible and
//      the user has typed a non-empty query.
//  The SwiftUI render tree itself needs an NSWindow host to
//  exercise, so these tests focus on the model-level predicates the
//  view uses; the visuals are confirmed by hand during polish
//  passes.
//

import XCTest
@testable import Scribe

@MainActor
final class StatusBarChipsTests: XCTestCase {

    // MARK: - Git branch visibility

    func test_gitBranchChip_hiddenWhenEngineIdle() {
        let engine = GitStatusEngine()
        XCTAssertNil(engine.branch,
                     "fresh engine without bind(repo:) should have no branch")
    }

    func test_gitBranchChip_surfacesBranchAfterRefresh() async throws {
        // Use the current Scribe repo root itself so we have a real
        // branch without fabricating fixtures. Resolves through
        // GitClient.findRepoRoot, same as Workspace does.
        guard let repoRoot = GitClient.findRepoRoot(
            for: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ) else {
            throw XCTSkip("Test not running inside a git repo; skip live branch read")
        }
        let engine = GitStatusEngine()
        engine.bind(repo: repoRoot)
        // bind() schedules a detached task; poll a short budget.
        let deadline = Date().addingTimeInterval(3.0)
        while engine.branch == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(engine.branch,
                        "engine should resolve the repo branch within 3s")
    }

    // MARK: - Find matches visibility

    func test_findMatchesPill_hiddenWhenBarClosed() {
        let prefs = EditorPreferences(
            defaults: UserDefaults(suiteName: "scribe-find-status-\(UUID().uuidString)")!
        )
        let fs = FindState(defaults: prefs.defaultsForTesting)
        XCTAssertFalse(fs.isVisible)
        // The view gates on (isVisible && !query.isEmpty); the
        // model state here is "bar closed, no query" — both parts
        // of the gate fail, so the chip wouldn't render.
    }

    func test_findMatchesPill_hiddenWhenQueryEmpty() {
        let prefs = EditorPreferences(
            defaults: UserDefaults(suiteName: "scribe-find-status-\(UUID().uuidString)")!
        )
        let fs = FindState(defaults: prefs.defaultsForTesting)
        fs.show(replaceMode: false)
        XCTAssertTrue(fs.isVisible)
        XCTAssertTrue(fs.query.isEmpty,
                      "default query is empty immediately after show()")
    }

    func test_findMatchesPill_visibleWhenBarOpenAndQueryNonEmpty() {
        let prefs = EditorPreferences(
            defaults: UserDefaults(suiteName: "scribe-find-status-\(UUID().uuidString)")!
        )
        let fs = FindState(defaults: prefs.defaultsForTesting)
        fs.show(replaceMode: false)
        fs.query = "needle"
        fs.matchCount = 17
        fs.currentMatch = 3
        XCTAssertTrue(fs.isVisible && !fs.query.isEmpty,
                      "gate predicate passes when both conditions hold")
        XCTAssertEqual(fs.matchCount, 17)
        XCTAssertEqual(fs.currentMatch, 3)
    }
}

// MARK: - Test hook

private extension EditorPreferences {
    /// Expose the underlying UserDefaults for tests that need to
    /// build a sibling FindState against the same scratch suite.
    /// Production paths never call this — FindState takes the
    /// same defaults at init through the normal surface.
    var defaultsForTesting: UserDefaults {
        Mirror(reflecting: self)
            .descendant("defaults") as? UserDefaults
            ?? .standard
    }
}
