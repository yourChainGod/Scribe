//
//  CrashRecoveryTests.swift
//  Phase 69 — covers the auto-save scratch + crash recovery loop:
//    * ScratchBufferStore persists + replays payload via index.json.
//    * Torn-write detection (contentLength mismatch) silently skips.
//    * Expiry pruning honours `retentionDays`.
//    * Workspace.captureScratch + save/close drop paths.
//    * CrashRecovery.detectPending flags external changes + missing files.
//    * CrashRecovery.apply reopens tabs, replaces placeholders, handles
//      the Untitled fallback, and drops consumed entries.
//    * EditorPreferences round-trips the three new keys.
//

import XCTest
@testable import Scribe

@MainActor
final class CrashRecoveryTests: XCTestCase {

    // MARK: - Scaffolding

    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-scratch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tmpDir.path) {
            try FileManager.default.removeItem(at: tmpDir)
        }
        try super.tearDownWithError()
    }

    /// UUID-suffixed UserDefaults suite so suites never collide.
    private func makePrefs() -> (EditorPreferences, () -> Void) {
        let suite = "scribe.scratch.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let prefs = EditorPreferences(defaults: defaults)
        return (prefs, {
            defaults.removePersistentDomain(forName: suite)
        })
    }

    private func makeStoreRoot() throws -> URL {
        let root = tmpDir.appendingPathComponent(UUID().uuidString,
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                 withIntermediateDirectories: true)
        return root
    }

    private func makeFixture(_ name: String, body: String = "disk\n") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url.standardizedFileURL
    }

    // MARK: - EditorPreferences round-trip

    func test_prefs_defaults_enabledDebounceAndRetention() {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        XCTAssertTrue(prefs.autoSaveScratchEnabled)
        XCTAssertEqual(prefs.autoSaveScratchDebounceSeconds, 3.0)
        XCTAssertEqual(prefs.autoSaveScratchRetentionDays, 7)
    }

    func test_prefs_roundTripAllKeys() {
        let suite = "scribe.scratch.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = EditorPreferences(defaults: defaults)
        prefs.autoSaveScratchEnabled = false
        prefs.autoSaveScratchDebounceSeconds = 5.5
        prefs.autoSaveScratchRetentionDays = 30

        let reloaded = EditorPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.autoSaveScratchEnabled)
        XCTAssertEqual(reloaded.autoSaveScratchDebounceSeconds, 5.5)
        XCTAssertEqual(reloaded.autoSaveScratchRetentionDays, 30)
    }

    func test_prefs_clampsOutOfRangeDebounce() {
        let suite = "scribe.scratch.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Simulate a corrupted plist that claims 0s debounce.
        defaults.set(0.0, forKey: "autoSave.scratch.debounceSeconds")
        let prefs = EditorPreferences(defaults: defaults)
        XCTAssertGreaterThanOrEqual(prefs.autoSaveScratchDebounceSeconds, 0.5)
    }

    // MARK: - ScratchBufferStore lifecycle

    func test_store_recordRoundTripsThroughIndex() throws {
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let id = UUID()
        store.record(id: id,
                     text: "hello world",
                     originalPath: "/tmp/alpha.txt",
                     title: "alpha.txt",
                     encoding: "utf8",
                     lineEnding: "lf",
                     diskMTime: Date(timeIntervalSince1970: 1_700_000_000),
                     diskSize: 100)
        // A second store over the same root should see the entry.
        let reloaded = ScratchBufferStore(root: root)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.readText(for: id), "hello world")
    }

    func test_store_recordReplacesExistingEntryById() throws {
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let id = UUID()
        store.record(id: id, text: "v1", originalPath: nil, title: "Untitled",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        store.record(id: id, text: "v2 updated", originalPath: nil, title: "Untitled",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.readText(for: id), "v2 updated")
    }

    func test_store_dropRemovesFileAndIndexEntry() throws {
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let id = UUID()
        store.record(id: id, text: "x", originalPath: nil, title: "u",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        store.drop(id: id)
        XCTAssertTrue(store.entries.isEmpty)
        let payloadURL = root.appendingPathComponent("\(id.uuidString).txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
    }

    func test_store_readText_tornWriteReturnsNil() throws {
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let id = UUID()
        store.record(id: id, text: "clean", originalPath: nil, title: "u",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        // Simulate a torn write by shortening the payload on disk
        // while leaving the index unchanged.
        let payloadURL = root.appendingPathComponent("\(id.uuidString).txt")
        try "xx".data(using: .utf8)!.write(to: payloadURL, options: [.atomic])
        let reloaded = ScratchBufferStore(root: root)
        XCTAssertNil(reloaded.readText(for: id),
                     "content-length mismatch should be treated as corrupt")
    }

    func test_store_pruneExpiredHonoursRetention() throws {
        let root = try makeStoreRoot()
        let fixedNow = Date(timeIntervalSince1970: 2_000_000)
        var stamp: Date = .distantPast
        let store = ScratchBufferStore(root: root, now: { stamp })
        // Entry A: 10 days ago → beyond 7-day window.
        stamp = fixedNow.addingTimeInterval(-10 * 86_400)
        store.record(id: UUID(), text: "old", originalPath: nil, title: "u",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        // Entry B: 1 day ago → survives.
        stamp = fixedNow.addingTimeInterval(-1 * 86_400)
        let keeper = UUID()
        store.record(id: keeper, text: "new", originalPath: nil, title: "u",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        stamp = fixedNow
        store.pruneExpired(retentionDays: 7)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, keeper)
    }

    func test_store_pruneExpired_zeroRetentionIsNoOp() throws {
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root,
                                       now: { Date(timeIntervalSince1970: 10) })
        store.record(id: UUID(), text: "x", originalPath: nil, title: "u",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        // Even with "0 days" retention, the forever sentinel skips the sweep.
        store.pruneExpired(retentionDays: 0)
        XCTAssertEqual(store.entries.count, 1)
    }

    func test_store_clearAllWipesBoth() throws {
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let id1 = UUID(), id2 = UUID()
        store.record(id: id1, text: "a", originalPath: nil, title: "u",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        store.record(id: id2, text: "b", originalPath: nil, title: "u",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        store.clearAll()
        XCTAssertTrue(store.entries.isEmpty)
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(contents, [], "scratch dir should be wiped")
    }

    // MARK: - Workspace capture / drop paths

    func test_workspace_capturesDirtyBufferAfterDebounce() async throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        prefs.autoSaveScratchDebounceSeconds = 0.5 // minimum clamp

        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let ws = Workspace(prefs: prefs,
                           openInitialUntitled: false,
                           scratchStore: store)
        let doc = Document(title: "Untitled", text: "")
        ws.documents.append(doc)
        ws.selectedID = doc.id
        // Simulate a real edit: flip dirty first, then text.
        doc.isDirty = true
        doc.text = "hello scratch"

        try await waitForEntries(in: store, count: 1, timeout: 2.0)
        XCTAssertEqual(store.entries.first?.id, doc.id)
        XCTAssertEqual(store.readText(for: doc.id), "hello scratch")
    }

    func test_workspace_dropsScratchOnSuccessfulSave() async throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        prefs.autoSaveScratchDebounceSeconds = 0.5

        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let ws = Workspace(prefs: prefs,
                           openInitialUntitled: false,
                           scratchStore: store)
        let saveURL = try makeFixture("saved.txt", body: "x")
        let doc = Document(title: "saved.txt", text: "", url: saveURL)
        ws.documents.append(doc)
        ws.selectedID = doc.id
        doc.isDirty = true
        doc.text = "new content"
        try await waitForEntries(in: store, count: 1, timeout: 2.0)

        // Simulate the user pressing ⌘S via Workspace.saveCurrent
        // (which hits the private `write` path). The doc has a url
        // so the non-large-file branch writes the text synchronously.
        ws.saveCurrent()
        XCTAssertTrue(store.entries.isEmpty,
                      "successful save must drop the scratch entry")
    }

    func test_workspace_dropsScratchOnClose() async throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        prefs.autoSaveScratchDebounceSeconds = 0.5

        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let ws = Workspace(prefs: prefs,
                           openInitialUntitled: false,
                           scratchStore: store)
        let doc = Document(title: "Untitled")
        ws.documents.append(doc)
        ws.selectedID = doc.id
        doc.isDirty = false // pretend clean so `close` doesn't modal
        doc.text = "transient"

        // Seed scratch by hand (bypassing debounce) so we can
        // verify close drops it without having to suppress the
        // dirty-close alert.
        store.record(id: doc.id, text: "transient", originalPath: nil,
                     title: "u", encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        XCTAssertEqual(store.entries.count, 1)

        ws.close(documentID: doc.id)
        XCTAssertTrue(store.entries.isEmpty,
                      "closing a tab must drop its scratch even if it was clean")
    }

    // MARK: - CrashRecovery

    func test_detectPending_nilWhenStoreEmpty() {
        let store = ScratchBufferStore(root: nil) // no-persistence store
        XCTAssertNil(CrashRecovery.detectPending(store: store))
    }

    func test_detectPending_flagsExternalChange() throws {
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let fileURL = try makeFixture("foo.txt", body: "current\n")
        // Record with fake old mtime so the probe thinks the file
        // has been modified since.
        store.record(id: UUID(), text: "pending",
                     originalPath: fileURL.path,
                     title: "foo.txt",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: Date(timeIntervalSince1970: 1),
                     diskSize: 0)
        let prompt = try XCTUnwrap(CrashRecovery.detectPending(store: store))
        XCTAssertEqual(prompt.items.count, 1)
        XCTAssertTrue(prompt.items[0].externalChanged)
        XCTAssertFalse(prompt.items[0].originalMissing)
    }

    func test_detectPending_flagsMissingFile() throws {
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        store.record(id: UUID(), text: "pending",
                     originalPath: "/tmp/does-not-exist-\(UUID().uuidString).txt",
                     title: "ghost.txt",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        let prompt = try XCTUnwrap(CrashRecovery.detectPending(store: store))
        XCTAssertTrue(prompt.items[0].originalMissing)
    }

    func test_apply_restoresUntitledEntry() throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let ws = Workspace(prefs: prefs,
                           openInitialUntitled: false,
                           scratchStore: store)

        let entryID = UUID()
        store.record(id: entryID, text: "my unsaved notes",
                     originalPath: nil, title: "Untitled",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        let prompt = try XCTUnwrap(CrashRecovery.detectPending(store: store))
        CrashRecovery.apply(selectedIDs: Set([entryID]),
                            store: store,
                            workspace: ws)
        XCTAssertEqual(ws.documents.count, 1)
        let doc = try XCTUnwrap(ws.documents.first)
        XCTAssertEqual(doc.text, "my unsaved notes")
        XCTAssertTrue(doc.isDirty)
        XCTAssertNil(doc.url)
        XCTAssertEqual(ws.selectedID, doc.id)
        XCTAssertTrue(store.entries.isEmpty,
                      "apply consumes the restored entry")
        _ = prompt // silence unused warning (also a reference to
                   // fail-fast if detectPending ever regresses to nil).
    }

    func test_apply_restoresWithURLWhenFileExists() throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let ws = Workspace(prefs: prefs,
                           openInitialUntitled: false,
                           scratchStore: store)

        let fileURL = try makeFixture("recoverable.txt", body: "disk version\n")
        let entryID = UUID()
        store.record(id: entryID, text: "scratch wins",
                     originalPath: fileURL.path,
                     title: "recoverable.txt",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        CrashRecovery.apply(selectedIDs: Set([entryID]),
                            store: store,
                            workspace: ws)
        XCTAssertEqual(ws.documents.count, 1)
        let doc = try XCTUnwrap(ws.documents.first)
        XCTAssertEqual(doc.text, "scratch wins")
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.url?.standardizedFileURL, fileURL)
    }

    func test_apply_fallsBackToUntitledWhenFileDeleted() throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let ws = Workspace(prefs: prefs,
                           openInitialUntitled: false,
                           scratchStore: store)

        let entryID = UUID()
        store.record(id: entryID, text: "still want this",
                     originalPath: "/tmp/vanished-\(UUID().uuidString).txt",
                     title: "vanished.txt",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        CrashRecovery.apply(selectedIDs: Set([entryID]),
                            store: store,
                            workspace: ws)
        XCTAssertEqual(ws.documents.count, 1)
        let doc = try XCTUnwrap(ws.documents.first)
        XCTAssertEqual(doc.text, "still want this")
        XCTAssertNil(doc.url, "missing original ⇒ Untitled fallback")
        XCTAssertTrue(doc.isDirty)
    }

    func test_apply_unselectedEntriesAreDropped() throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let ws = Workspace(prefs: prefs,
                           openInitialUntitled: false,
                           scratchStore: store)

        let keep = UUID(), drop = UUID()
        store.record(id: keep, text: "keep", originalPath: nil, title: "k",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        store.record(id: drop, text: "drop", originalPath: nil, title: "d",
                     encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        CrashRecovery.apply(selectedIDs: Set([keep]),
                            store: store,
                            workspace: ws)
        XCTAssertEqual(ws.documents.count, 1)
        XCTAssertEqual(ws.documents.first?.text, "keep")
        XCTAssertTrue(store.entries.isEmpty,
                      "both selected and unselected entries must be dropped")
    }

    func test_discardAll_wipesWithoutOpeningTabs() throws {
        let (prefs, cleanup) = makePrefs()
        defer { cleanup() }
        let root = try makeStoreRoot()
        let store = ScratchBufferStore(root: root)
        let ws = Workspace(prefs: prefs,
                           openInitialUntitled: false,
                           scratchStore: store)

        store.record(id: UUID(), text: "throwaway", originalPath: nil,
                     title: "u", encoding: "utf8", lineEnding: "lf",
                     diskMTime: nil, diskSize: nil)
        CrashRecovery.discardAll(store: store)
        XCTAssertTrue(ws.documents.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Helpers

    /// Pump the main runloop until the store sees `count` entries or
    /// the deadline expires. Combine's debounce hops through
    /// DispatchQueue.main so a plain `await Task.sleep` wouldn't give
    /// the sink a chance to fire.
    private func waitForEntries(in store: ScratchBufferStore,
                                count: Int,
                                timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.entries.count < count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(store.entries.count, count,
                       "scratch store did not reach expected entry count")
    }
}
