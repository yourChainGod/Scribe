//
//  WorkspaceTabPinTests.swift
//  Phase 46b — covers `Workspace.togglePin(_:)` and `resortByPin()`
//  plus the open-file re-apply path. Focuses on the data model;
//  the TabBarView pin glyph / context menu is visually smoke-
//  tested by hand (no headless NSView harness yet).
//

import Combine
import XCTest
@testable import Scribe

@MainActor
final class WorkspaceTabPinTests: XCTestCase {

    private func suiteName() -> String { "scribe-pin-\(UUID().uuidString)" }

    private func makePrefs(suite: String) -> EditorPreferences {
        EditorPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    private func makeWorkspace(prefs: EditorPreferences) -> Workspace {
        Workspace(prefs: prefs, openInitialUntitled: false)
    }

    private func attach(docs: [Document], to ws: Workspace) {
        ws.documents = docs
    }

    // MARK: - togglePin / basics

    func test_togglePin_flipsDocumentFlag() {
        let prefs = makePrefs(suite: suiteName())
        let ws = makeWorkspace(prefs: prefs)
        let doc = Document(title: "a.md",
                           text: "x",
                           url: URL(fileURLWithPath: "/tmp/a.md"))
        ws.documents = [doc]

        ws.togglePin(doc)
        XCTAssertTrue(doc.isPinned)

        ws.togglePin(doc)
        XCTAssertFalse(doc.isPinned)
    }

    func test_togglePin_persistsUrlPathInPrefs() {
        let suite = suiteName()
        let prefs = makePrefs(suite: suite)
        let ws = makeWorkspace(prefs: prefs)
        let url = URL(fileURLWithPath: "/tmp/sticky.md")
        let doc = Document(title: "sticky.md", url: url)
        ws.documents = [doc]

        ws.togglePin(doc)
        XCTAssertTrue(prefs.pinnedFilePaths.contains(url.standardizedFileURL.path))

        ws.togglePin(doc)
        XCTAssertFalse(prefs.pinnedFilePaths.contains(url.standardizedFileURL.path))
    }

    func test_togglePin_doesNotPersistUntitledDoc() {
        let prefs = makePrefs(suite: suiteName())
        let ws = makeWorkspace(prefs: prefs)
        let doc = Document(title: "Untitled")  // url == nil
        ws.documents = [doc]

        ws.togglePin(doc)
        XCTAssertTrue(doc.isPinned, "in-memory flag still flips")
        XCTAssertTrue(prefs.pinnedFilePaths.isEmpty,
                      "Untitled docs can't key into the persisted set")
    }

    // MARK: - resortByPin

    func test_togglePin_floatsPinnedToHead() {
        let prefs = makePrefs(suite: suiteName())
        let ws = makeWorkspace(prefs: prefs)
        let a = Document(title: "A", url: URL(fileURLWithPath: "/tmp/A"))
        let b = Document(title: "B", url: URL(fileURLWithPath: "/tmp/B"))
        let c = Document(title: "C", url: URL(fileURLWithPath: "/tmp/C"))
        attach(docs: [a, b, c], to: ws)

        ws.togglePin(c) // pin the last doc
        XCTAssertEqual(ws.documents.map(\.title), ["C", "A", "B"])
    }

    func test_resortByPin_isStableAcrossGroups() {
        let prefs = makePrefs(suite: suiteName())
        let ws = makeWorkspace(prefs: prefs)
        let a = Document(title: "A", url: URL(fileURLWithPath: "/tmp/A"))
        let b = Document(title: "B", url: URL(fileURLWithPath: "/tmp/B"))
        let c = Document(title: "C", url: URL(fileURLWithPath: "/tmp/C"))
        let d = Document(title: "D", url: URL(fileURLWithPath: "/tmp/D"))
        a.isPinned = true
        c.isPinned = true
        attach(docs: [a, b, c, d], to: ws)
        ws.resortByPin()
        // Pinned [A, C] first in original relative order, then
        // unpinned [B, D] preserved likewise.
        XCTAssertEqual(ws.documents.map(\.title), ["A", "C", "B", "D"])
    }

    func test_resortByPin_noOpWhenOrderAlreadyCorrect() {
        let prefs = makePrefs(suite: suiteName())
        let ws = makeWorkspace(prefs: prefs)
        let a = Document(title: "A")
        let b = Document(title: "B")
        a.isPinned = true
        attach(docs: [a, b], to: ws)

        // Expect no objectWillChange tick because array order matches
        // the pinned-first invariant already.
        var changes = 0
        let cancellable = ws.objectWillChange.sink { _ in changes += 1 }
        ws.resortByPin()
        cancellable.cancel()
        XCTAssertEqual(changes, 0)
    }

    // MARK: - selection stability

    func test_togglePin_keepsSelectedIDStable() {
        let prefs = makePrefs(suite: suiteName())
        let ws = makeWorkspace(prefs: prefs)
        let a = Document(title: "A", url: URL(fileURLWithPath: "/tmp/A"))
        let b = Document(title: "B", url: URL(fileURLWithPath: "/tmp/B"))
        attach(docs: [a, b], to: ws)
        ws.selectedID = b.id

        ws.togglePin(b)
        // b floats to head but the same doc remains active.
        XCTAssertEqual(ws.documents.map(\.title), ["B", "A"])
        XCTAssertEqual(ws.selectedID, b.id)
    }

    // MARK: - persistence across workspace instances

    func test_pinPersistence_surfacesInFreshWorkspace() {
        let suite = suiteName()
        let url = URL(fileURLWithPath: "/tmp/sticky.md")

        // Workspace A pins the doc.
        let prefsA = makePrefs(suite: suite)
        let wsA = makeWorkspace(prefs: prefsA)
        let docA = Document(title: "sticky.md", url: url)
        wsA.documents = [docA]
        wsA.togglePin(docA)
        XCTAssertTrue(prefsA.pinnedFilePaths.contains(url.standardizedFileURL.path))

        // Workspace B (new prefs instance over the same suite)
        // should find the path in its loaded set.
        let prefsB = makePrefs(suite: suite)
        XCTAssertTrue(prefsB.pinnedFilePaths.contains(url.standardizedFileURL.path),
                      "second EditorPreferences reads the same UserDefaults suite")
    }

    func test_openFile_restoresPinForPreviouslyPinnedUrl() throws {
        // Seed the prefs directly with a pinned path, then open the
        // file through Workspace.openFile(at:) and confirm the new
        // doc arrived with isPinned already set.
        let suite = suiteName()
        let prefs = makePrefs(suite: suite)

        // Write a temporary file so openFile can actually read it.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-pin-\(UUID().uuidString).txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        prefs.pinnedFilePaths = [fileURL.standardizedFileURL.path]

        let ws = makeWorkspace(prefs: prefs)
        ws.openFile(at: fileURL)
        guard let opened = ws.documents.first(where: { $0.url?.standardizedFileURL == fileURL.standardizedFileURL }) else {
            return XCTFail("openFile did not surface the doc")
        }
        XCTAssertTrue(opened.isPinned,
                      "pinned URL in prefs should re-apply on open")
    }
}
