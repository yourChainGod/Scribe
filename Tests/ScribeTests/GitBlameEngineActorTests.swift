//
//  GitBlameEngineActorTests.swift
//  Phase 45-E — regression-test the actor isolation contract for
//  the inline-blame fetch path. `GitClient.parseBlamePorcelain` runs
//  on a `Task.detached(.userInitiated)` from `GitBlameEngine.request`,
//  not on the main actor. perf_audit.md § 4 P1 #2 calls this out as a
//  "verify, don't refactor" task — these tests pin the contract so a
//  future refactor that accidentally collapses the detached hop
//  surfaces here instead of as a typing-time freeze on a 5MB file.
//
//  How the tests work:
//    Each test spins up a throwaway git repo (mirrors
//    GitClientWriteIntegrationTests' setUp), seeds README.md, and
//    drives `GitBlameEngine` against it. Because the test function
//    is itself running on @MainActor, the engine's
//    `await handleResult(...)` hop cannot land on the main actor
//    until the test yields. That gives us a synchronous window
//    where we can assert the cache is *still empty* — which is
//    only true if the parse really happened off-main.
//

import Combine
import XCTest
@testable import Scribe

@MainActor
final class GitBlameEngineActorTests: XCTestCase {

    private var repoURL: URL!
    private var fileURL: URL!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
            "/usr/bin/git not available on this runner"
        )
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-blame-actor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp,
                                                withIntermediateDirectories: true)
        repoURL = tmp
        try runGit(["init", "--quiet"])
        try runGit(["config", "user.email", "test@scribe.app"])
        try runGit(["config", "user.name", "Scribe Test"])
        let readme = repoURL.appendingPathComponent("README.md")
        try "initial\nsecond line\nthird line\n"
            .write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"])
        try runGit(["commit", "-m", "initial", "--quiet"])
        fileURL = readme.resolvingSymlinksInPath()
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        if let repoURL {
            try? FileManager.default.removeItem(at: repoURL)
        }
        repoURL = nil
        fileURL = nil
        try await super.tearDown()
    }

    // MARK: - Invariant: request never blocks main actor

    /// `request(for:)` schedules `git blame` on a detached task and
    /// returns immediately. Because the test method runs on
    /// @MainActor, the detached task's `await handleResult` cannot
    /// land until we yield — so the cache must still be `nil` at
    /// the synchronous return point. If a future refactor inlines
    /// the work on main, this assertion fires.
    func test_request_doesNotSynchronouslyFillCache() async throws {
        let engine = GitBlameEngine()
        XCTAssertNil(engine.blameLines(for: fileURL),
                     "engine starts cold")

        engine.request(for: fileURL)

        XCTAssertNil(engine.blameLines(for: fileURL),
                     "request must not synchronously fill the cache; "
                     + "detached Task should still be running git")

        let landed = expectation(description: "blame lands on main")
        engine.$blameByURL
            .dropFirst()
            .sink { [fileURL] map in
                if let key = fileURL?.standardizedFileURL,
                   map[key] != nil {
                    landed.fulfill()
                }
            }
            .store(in: &cancellables)
        await fulfillment(of: [landed], timeout: 5.0)

        let lines = engine.blameLines(for: fileURL)
        XCTAssertNotNil(lines, "blame must land after detached task completes")
        XCTAssertEqual(lines?.count, 3, "README seeded with 3 lines")
        XCTAssertNotNil(lines?[1], "line 1 should map to a BlameLine")
    }

    /// `refresh(for:)` is `invalidate + request`. The invalidate is
    /// synchronous (drops the cache entry immediately) but the
    /// re-fetch must be detached just like `request`.
    func test_refresh_dropsCacheSyncAndReFetchesAsync() async throws {
        let engine = GitBlameEngine()

        // Prime the cache.
        engine.request(for: fileURL)
        let firstLand = expectation(description: "first blame lands")
        engine.$blameByURL
            .dropFirst()
            .sink { [fileURL] map in
                if let key = fileURL?.standardizedFileURL,
                   map[key] != nil {
                    firstLand.fulfill()
                }
            }
            .store(in: &cancellables)
        await fulfillment(of: [firstLand], timeout: 5.0)
        XCTAssertNotNil(engine.blameLines(for: fileURL))

        // Refresh — cache should drop immediately, re-fetch must
        // be detached so we can still observe the empty window.
        cancellables.removeAll()
        engine.refresh(for: fileURL)
        XCTAssertNil(engine.blameLines(for: fileURL),
                     "refresh drops cache synchronously")

        let reLand = expectation(description: "refresh re-lands")
        engine.$blameByURL
            .dropFirst()
            .sink { [fileURL] map in
                if let key = fileURL?.standardizedFileURL,
                   map[key] != nil {
                    reLand.fulfill()
                }
            }
            .store(in: &cancellables)
        await fulfillment(of: [reLand], timeout: 5.0)
        XCTAssertNotNil(engine.blameLines(for: fileURL),
                       "refresh re-fetch must land asynchronously")
    }

    /// Hammer `request` on the same URL: the in-flight short-circuit
    /// + cache hit must collapse the storm into a single fetch. If
    /// the detached hop ever became synchronous and the cache was
    /// filled in-line, this would still pass — so we *also* assert
    /// the synchronous-empty window from the first call. That gives
    /// the in-flight invariant a real teeth: a tab-switch storm
    /// across N tabs scales O(1), not O(N), against the same URL.
    func test_request_inFlightCollapsesDuplicateCalls() async throws {
        let engine = GitBlameEngine()

        for _ in 0..<5 { engine.request(for: fileURL) }

        XCTAssertNil(engine.blameLines(for: fileURL),
                     "all 5 requests are still detached; cache empty")

        let landed = expectation(description: "blame lands once")
        landed.assertForOverFulfill = true
        engine.$blameByURL
            .dropFirst()
            .sink { [fileURL] map in
                if let key = fileURL?.standardizedFileURL,
                   map[key] != nil {
                    landed.fulfill()
                }
            }
            .store(in: &cancellables)
        await fulfillment(of: [landed], timeout: 5.0)
    }

    // MARK: - Helpers

    @discardableResult
    private func runGit(_ args: [String]) throws -> String {
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
            throw NSError(domain: "git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
