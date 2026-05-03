//
//  SessionRestoreTests.swift
//  Phase 67d — covers the persist-and-restore loop for editor tabs:
//    * Workspace mirrors the URLs of every titled tab into prefs as
//      the user adds / closes / re-orders documents.
//    * EditorPreferences round-trips both keys through UserDefaults.
//    * SessionRestore.apply re-opens the persisted set on the next
//      launch, drops missing files, and honours the selection
//      fallback rules.
//
//  We use ad-hoc UserDefaults suites + tmp file URLs so the test
//  run never touches the developer's real defaults / disk state.
//

import XCTest
@testable import Scribe

@MainActor
final class SessionRestoreTests: XCTestCase {

    // MARK: - Test scaffolding

    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-session-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tmpDir.path) {
            try FileManager.default.removeItem(at: tmpDir)
        }
        try super.tearDownWithError()
    }

    /// Convenience: write a tiny text file under `tmpDir` and return
    /// the standardised URL the workspace should see.
    private func makeFixture(_ name: String, body: String = "// fixture\n") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url.standardizedFileURL
    }

    /// Fresh per-test prefs backed by a UUID-suffixed UserDefaults
    /// suite so two tests can't see each other's writes. The
    /// returned closure tears the suite down at end-of-test.
    private func makePrefs() -> (EditorPreferences, () -> Void) {
        let suite = "scribe.session.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let prefs = EditorPreferences(defaults: defaults)
        return (prefs, {
            defaults.removePersistentDomain(forName: suite)
        })
    }

    // MARK: - EditorPreferences round-trip

    func test_prefs_emptyDefaults_returnsEmptyAndNil() {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        XCTAssertEqual(prefs.sessionOpenFilePaths, [])
        XCTAssertNil(prefs.sessionSelectedFilePath)
    }

    func test_prefs_persistOpenFilePaths_roundTrip() throws {
        let suite = "scribe.session.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = EditorPreferences(defaults: defaults)
        prefs.sessionOpenFilePaths = ["/tmp/a.txt", "/tmp/b.txt"]
        prefs.sessionSelectedFilePath = "/tmp/b.txt"

        let reloaded = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.sessionOpenFilePaths, ["/tmp/a.txt", "/tmp/b.txt"])
        XCTAssertEqual(reloaded.sessionSelectedFilePath, "/tmp/b.txt")
    }

    func test_prefs_clearingSelectedPath_removesKey() {
        let suite = "scribe.session.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = EditorPreferences(defaults: defaults)
        prefs.sessionSelectedFilePath = "/tmp/x"
        prefs.sessionSelectedFilePath = nil

        XCTAssertNil(defaults.object(forKey: "session.selectedFilePath"),
                     "setting nil must remove the key, not stash an empty string")
    }

    // MARK: - Workspace persistence sinks

    func test_workspace_openFile_pushesPathIntoPrefs() throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }

        let ws = Workspace(prefs: prefs, openInitialUntitled: false)
        let url = try makeFixture("alpha.txt")
        ws.openFile(at: url)

        // The sink runs on the main runloop one tick after the
        // openFile call. Spin once so didSet / Combine deliver.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(prefs.sessionOpenFilePaths, [url.path])
        XCTAssertEqual(prefs.sessionSelectedFilePath, url.path)
    }

    func test_workspace_untitledTab_doesNotPersist() {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }

        // openInitialUntitled creates a single Untitled doc; nothing
        // should leak into the persisted snapshot because Untitled
        // docs have no URL.
        let ws = Workspace(prefs: prefs, openInitialUntitled: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(prefs.sessionOpenFilePaths, [])
        XCTAssertNil(prefs.sessionSelectedFilePath)
        XCTAssertEqual(ws.documents.count, 1, "Untitled doc was created")
    }

    func test_workspace_closeTab_removesPath() throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }

        let ws = Workspace(prefs: prefs, openInitialUntitled: false)
        let a = try makeFixture("a.txt")
        let b = try makeFixture("b.txt")
        ws.openFile(at: a)
        ws.openFile(at: b)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(prefs.sessionOpenFilePaths, [a.path, b.path])

        guard let aDoc = ws.documents.first(where: {
            $0.url?.standardizedFileURL == a
        }) else {
            XCTFail("expected fixture A to be open")
            return
        }
        ws.close(documentID: aDoc.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(prefs.sessionOpenFilePaths, [b.path],
                       "closing a tab must remove its path from prefs")
    }

    // MARK: - SessionRestore.usableRestorePaths

    func test_usableRestorePaths_filtersMissingFiles() throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }

        let real = try makeFixture("real.txt")
        let ghost = tmpDir.appendingPathComponent("ghost.txt").path

        prefs.sessionOpenFilePaths = [ghost, real.path]
        let usable = SessionRestore.usableRestorePaths(prefs: prefs)

        XCTAssertEqual(usable, [real],
                       "missing files must be filtered out")
    }

    func test_usableRestorePaths_emptyWhenAllMissing() {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        prefs.sessionOpenFilePaths = ["/tmp/never-existed-\(UUID()).txt"]
        XCTAssertTrue(SessionRestore.usableRestorePaths(prefs: prefs).isEmpty)
    }

    // MARK: - SessionRestore.selectionTarget

    func test_selectionTarget_nilFallback_pickFirst() throws {
        let a = try makeFixture("a.txt")
        let b = try makeFixture("b.txt")
        let target = SessionRestore.selectionTarget(from: nil, in: [a, b])
        XCTAssertEqual(target, a)
    }

    func test_selectionTarget_persistedAndPresent_picksMatch() throws {
        let a = try makeFixture("a.txt")
        let b = try makeFixture("b.txt")
        let target = SessionRestore.selectionTarget(from: b.path, in: [a, b])
        XCTAssertEqual(target, b)
    }

    func test_selectionTarget_persistedButMissing_fallsBackToFirst() throws {
        let a = try makeFixture("a.txt")
        let b = try makeFixture("b.txt")
        let stale = "/tmp/no-such-file-\(UUID()).txt"
        let target = SessionRestore.selectionTarget(from: stale, in: [a, b])
        XCTAssertEqual(target, a)
    }

    func test_selectionTarget_emptyUsable_returnsNil() {
        let target = SessionRestore.selectionTarget(from: "/tmp/x", in: [])
        XCTAssertNil(target)
    }

    // MARK: - SessionRestore.apply

    func test_apply_skipFlag_isNoOp() throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        let url = try makeFixture("alpha.txt")
        prefs.sessionOpenFilePaths = [url.path]

        let ws = Workspace(prefs: prefs, openInitialUntitled: false)
        SessionRestore.apply(prefs: prefs, to: ws, skip: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(ws.documents.isEmpty,
                      "skip:true must keep the workspace as the caller seeded it")
    }

    func test_apply_emptyPrefs_isNoOp() {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        let ws = Workspace(prefs: prefs, openInitialUntitled: false)
        SessionRestore.apply(prefs: prefs, to: ws, skip: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(ws.documents.isEmpty)
    }

    func test_apply_reopensPersistedTabs() throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        let a = try makeFixture("a.txt")
        let b = try makeFixture("b.txt")
        prefs.sessionOpenFilePaths = [a.path, b.path]
        prefs.sessionSelectedFilePath = b.path

        let ws = Workspace(prefs: prefs, openInitialUntitled: false)
        SessionRestore.apply(prefs: prefs, to: ws, skip: false)

        // SessionRestore queues openFile via DispatchQueue.main.async;
        // pump the runloop until the tabs land *and* the deferred
        // selection restoration runs (which itself hops once more via
        // main async to let the openFile sync paths settle).
        let deadline = Date().addingTimeInterval(0.7)
        while (ws.documents.count < 2
               || ws.documents.first(where: { $0.id == ws.selectedID })?
                    .url?.standardizedFileURL != b)
              && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(ws.documents.compactMap { $0.url?.standardizedFileURL.path },
                       [a.path, b.path])
        let selected = ws.documents.first(where: { $0.id == ws.selectedID })?
            .url?.standardizedFileURL
        XCTAssertEqual(selected, b,
                       "persisted selection should win over the openFile loop's default")
    }

    func test_apply_dropsMissingPathsButRestoresSurvivors() throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        let live = try makeFixture("alive.txt")
        let dead = tmpDir.appendingPathComponent("gone.txt").path
        prefs.sessionOpenFilePaths = [dead, live.path]

        let ws = Workspace(prefs: prefs, openInitialUntitled: false)
        SessionRestore.apply(prefs: prefs, to: ws, skip: false)

        let deadline = Date().addingTimeInterval(0.5)
        while ws.documents.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(ws.documents.count, 1,
                       "missing path must drop out, surviving path opens")
        XCTAssertEqual(ws.documents.first?.url?.standardizedFileURL, live)
    }
}
